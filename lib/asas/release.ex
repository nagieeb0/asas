defmodule Asas.Release do
  @moduledoc """
  Migrate and seed from inside a release, where there is no Mix.

      defmodule MyApp.Release do
        use Asas.Release, otp_app: :my_app, seeded_check: "menu_categories"
      end

  then in the entrypoint (or `Application.start/2` on a platform with no
  release-command hook):

      MyApp.Release.migrate()
      MyApp.Release.seed()

  ## Why `seed/0` needs an advisory lock

  "Skip when populated" is a read followed by a write, and on the very first
  deploy that is a race. Two containers starting together — a rolling deploy,
  or a crash loop restarting while the replacement boots — both read an empty
  table, both decide to seed, and the app opens with every row listed twice.
  That is not hypothetical: it is what happened on one of these apps' first
  successful boot, 28 categories for 14 names.

  `pg_try_advisory_lock` closes it. Whoever takes the lock seeds; whoever
  cannot does not wait and does not seed, because the holder is doing the
  identical work. The lock is session-scoped, so Postgres drops it if the
  connection dies and a container killed mid-seed cannot wedge the next one.
  The check is repeated *inside* the lock — that is what makes the pair
  correct, since the loser of the race takes the lock after the winner has
  finished.

  ## Why `to_regclass`, in two statements

  The very first boot runs this immediately after the migration that creates
  the table. On any path where that has not happened, "no table" has to mean
  "not seeded" rather than an exception that takes the container down.

  The check is deliberately two queries. Folding it into one

      SELECT CASE WHEN to_regclass(...) IS NULL THEN false
                  ELSE EXISTS (SELECT 1 FROM t) END

  reads as though the `CASE` guards the `SELECT`. It does not: Postgres resolves
  relations when it parses the statement, before any branch is evaluated, so the
  whole query fails with `relation "t" does not exist` and the guard never gets
  a chance to run. That one-statement form shipped here and was only caught by a
  test against a real database.

  Migrations run on every boot because they are versioned and know what they
  have already applied. The seed has no such record, so `seeded_check` — the
  name of a table that is non-empty once seeding has happened — is its version
  table.
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app)
    seeded_check = Keyword.get(opts, :seeded_check)
    seeded_where = Keyword.get(opts, :seeded_where)
    seed_file = Keyword.get(opts, :seed_file, "priv/repo/seeds.exs")

    # Folded here, where `seeded_where` is a plain value, rather than left as an
    # `if` inside the quote. Generated as `" WHERE " <> @seeded_where`, the type
    # checker reads the dead branch of a host app that passes no predicate as
    # `nil <> binary()` and every such app compiles with a warning it cannot fix
    # from its own source — which is fatal under `--warnings-as-errors`.
    seeded_where_sql = if seeded_where, do: " WHERE " <> seeded_where, else: ""

    quote do
      @app unquote(otp_app)
      @seeded_check unquote(seeded_check)
      # Optional predicate. my_coffee's marker is not "the users table has rows"
      # but "a root user exists", because the table is non-empty the moment
      # anyone signs up. Without this the gate would report seeded before the
      # seed had run.
      @seeded_where_sql unquote(seeded_where_sql)
      @seed_file unquote(seed_file)
      # Any stable 64-bit integer; phash2 over the app name keeps it stable
      # across builds without anyone having to remember a magic number.
      @seed_lock :erlang.phash2({unquote(otp_app), :release_seed}, 2_147_483_647)

      def migrate do
        load_app()

        for repo <- repos() do
          {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
        end

        :ok
      end

      def rollback(repo, version) do
        load_app()
        {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
      end

      def seed do
        load_app()
        for repo <- repos(), do: {:ok, _, _} = Ecto.Migrator.with_repo(repo, &seed_once/1)
        :ok
      end

      # Two gates, cheapest first. seeded?/1 is one EXISTS against an index; on
      # every boot after the first it answers in a millisecond and nothing else
      # runs — in particular not Code.eval_file/1, which recompiles the seed
      # script from source every time it is reached.
      defp seed_once(repo) do
        cond do
          seeded?(repo) ->
            IO.puts("seed: already applied — skipped")

          not lock(repo) ->
            IO.puts("seed: another node holds the lock — skipped")

          true ->
            try do
              if seeded?(repo) do
                IO.puts("seed: applied by another node while waiting — skipped")
              else
                @app |> Application.app_dir(@seed_file) |> Code.eval_file()
              end
            after
              Ecto.Adapters.SQL.query!(repo, "SELECT pg_advisory_unlock($1)", [@seed_lock])
            end
        end
      end

      if @seeded_check do
        # Two statements, not one. The very first boot runs this right after the
        # migration that creates the table, and on any path where that has not
        # happened "no table" must mean "not seeded" rather than an exception
        # that takes the container down.
        #
        # This used to be a single CASE ... to_regclass(...) IS NULL ... ELSE
        # EXISTS (SELECT 1 FROM t) END, which reads as if the CASE guards the
        # SELECT. It does not. Postgres resolves relations when it parses the
        # statement, before any branch is evaluated, so the whole query fails
        # with `relation "t" does not exist` and the guard never runs:
        #
        #     ERROR:  relation "a_table_that_is_never_created" does not exist
        #
        # Splitting it is the only way the check can actually tolerate a missing
        # table. The second query is skipped entirely when the first says no.
        defp seeded?(repo) do
          exists =
            Ecto.Adapters.SQL.query!(
              repo,
              "SELECT to_regclass($1) IS NOT NULL",
              ["public.#{@seeded_check}"]
            )

          if match?(%{rows: [[true]]}, exists) do
            match?(
              %{rows: [[true]]},
              Ecto.Adapters.SQL.query!(
                repo,
                "SELECT EXISTS (SELECT 1 FROM #{@seeded_check}#{@seeded_where_sql})"
              )
            )
          else
            false
          end
        end
      else
        # No marker table named: the lock still makes concurrent boots safe, but
        # the seed script itself has to be idempotent.
        defp seeded?(_repo), do: false
      end

      defp lock(repo) do
        match?(
          %{rows: [[true]]},
          Ecto.Adapters.SQL.query!(repo, "SELECT pg_try_advisory_lock($1)", [@seed_lock])
        )
      end

      defp repos, do: Application.fetch_env!(@app, :ecto_repos)

      defp load_app do
        # Many platforms require SSL when connecting to the database.
        Application.ensure_all_started(:ssl)
        Application.ensure_loaded(@app)
      end
    end
  end
end

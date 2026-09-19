defmodule Asas.ReleaseTest do
  @moduledoc """
  `Asas.Release` against a real Postgres.

  The existing coverage asserted `function_exported?` for migrate/0, rollback/2
  and seed/0 — i.e. that the macro expands. The advisory lock and the
  double-checked marker read, which are the entire reason this module exists,
  had never executed. The incident its moduledoc describes ("28 categories for 14
  names") is a seed that ran twice, and nothing in the suite could have caught it.

  These need a database. `pg_try_advisory_lock` semantics — one holder, released
  on unlock, visible to a second connection — are Postgres behaviour, and a mock
  asserting our own assumptions back at us would be worse than no test.
  """

  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL

  defmodule Release do
    @moduledoc false
    use Asas.Release,
      otp_app: :asas,
      seeded_check: "asas_seed_marker",
      seed_file: "priv/test_seeds.exs"
  end

  defmodule MissingMarkerRelease do
    @moduledoc false
    use Asas.Release,
      otp_app: :asas,
      seeded_check: "a_table_that_is_never_created",
      seed_file: "priv/test_seeds.exs"
  end

  setup_all do
    config = Application.fetch_env!(:asas, Asas.TestRepo)

    # storage_up is idempotent enough: :already_up is a fine outcome.
    case Ecto.Adapters.Postgres.storage_up(config) do
      :ok -> :ok
      {:error, :already_up} -> :ok
      {:error, reason} -> raise "could not create asas_test: #{inspect(reason)}"
    end

    :ok
  end

  setup do
    {:ok, _, _} =
      Ecto.Migrator.with_repo(Asas.TestRepo, fn repo ->
        SQL.query!(repo, "DROP TABLE IF EXISTS asas_seed_marker", [])

        SQL.query!(
          repo,
          "CREATE TABLE asas_seed_marker (id bigserial primary key, note text)",
          []
        )
      end)

    :ok
  end

  defp marker_count do
    {:ok, count, _} =
      Ecto.Migrator.with_repo(Asas.TestRepo, fn repo ->
        %{rows: [[n]]} = SQL.query!(repo, "SELECT count(*) FROM asas_seed_marker", [])
        n
      end)

    count
  end

  describe "seed/0" do
    test "runs the seed script exactly once, however many times it is called" do
      assert marker_count() == 0

      assert :ok = Release.seed()
      assert marker_count() == 1

      # The second call is the one that matters. The seed script itself appends
      # unconditionally, so if the marker gate did not hold this would be 2 — the
      # "28 categories for 14 names" shape.
      assert :ok = Release.seed()
      assert marker_count() == 1

      assert :ok = Release.seed()
      assert marker_count() == 1
    end

    test "a marker table that does not exist reads as 'not seeded' instead of raising" do
      # to_regclass is the reason this is a false rather than an exception. On a
      # first boot the seed runs immediately after the migration that creates the
      # table, and any path where that has not happened must not take the
      # container down.
      #
      # Proved by pointing the gate at a table that is never created while the
      # seed script writes to one that exists: if to_regclass raised, the script
      # would never run and the count would stay 0.
      assert marker_count() == 0

      assert :ok = MissingMarkerRelease.seed()
      assert marker_count() == 1

      # And the documented consequence: with no usable marker, the gate can never
      # say "already seeded", so every boot re-runs the script. That is why the
      # moduledoc tells you to name a seeded_check.
      assert :ok = MissingMarkerRelease.seed()
      assert marker_count() == 2
    end
  end

  describe "the advisory lock" do
    test "is released after seeding, so the next boot is not blocked forever" do
      assert :ok = Release.seed()

      lock_id = :erlang.phash2({:asas, :release_seed}, 2_147_483_647)

      {:ok, held, _} =
        Ecto.Migrator.with_repo(Asas.TestRepo, fn repo ->
          %{rows: [[taken]]} =
            SQL.query!(repo, "SELECT pg_try_advisory_lock($1)", [lock_id])

          if taken, do: SQL.query!(repo, "SELECT pg_advisory_unlock($1)", [lock_id])

          taken
        end)

      assert held, "seed/0 left the advisory lock held; the next boot would skip forever"
    end

    test "a held lock makes seed/0 skip rather than block or double-apply" do
      lock_id = :erlang.phash2({:asas, :release_seed}, 2_147_483_647)

      # A separate connection holds the lock for the duration, standing in for
      # another node booting at the same moment.
      {:ok, holder} = Postgrex.start_link(Application.fetch_env!(:asas, Asas.TestRepo))
      %{rows: [[true]]} = Postgrex.query!(holder, "SELECT pg_try_advisory_lock($1)", [lock_id])

      try do
        output = ExUnit.CaptureIO.capture_io(fn -> assert :ok = Release.seed() end)

        assert output =~ "another node holds the lock"
        assert marker_count() == 0, "seed ran while another node held the lock"
      after
        Postgrex.query!(holder, "SELECT pg_advisory_unlock($1)", [lock_id])
        GenServer.stop(holder)
      end
    end
  end
end

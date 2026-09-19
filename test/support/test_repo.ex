defmodule Asas.TestRepo do
  @moduledoc """
  A real Postgres repo, used only by `Asas.ReleaseTest`.

  `Asas.Release`'s whole reason to exist is `pg_try_advisory_lock` plus a
  double-checked marker read. Neither can be exercised by a mock: the point is
  what Postgres does when two connections ask for the same lock.
  """
  use Ecto.Repo, otp_app: :asas, adapter: Ecto.Adapters.Postgres
end

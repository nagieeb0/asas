defmodule Asas.FakeRelease do
  @moduledoc "Compile-time smoke target for the `Asas.Release` macro. Never run against a DB."
  use Asas.Release, otp_app: :asas, seeded_check: "menu_categories"
end

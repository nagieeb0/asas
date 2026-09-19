defmodule Asas.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/nagieeb0/asas"

  def project do
    [
      app: :asas,
      version: @version,
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "Asas",
      source_url: @source_url
    ]
  end

  def application, do: [extra_applications: [:logger]]

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp description do
    "The seven things every one of these Phoenix/Ash apps rewrote from scratch."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      source_ref: "v#{@version}",
      extras: ["README.md", "CHANGELOG.md"]
    ]
  end

  defp deps do
    [
      {:req, "~> 0.5"},
      # Optional: only the modules that need them will fail to compile without them,
      # and every host app already has all four.
      {:plug, "~> 1.16", optional: true},
      {:phoenix_live_view, "~> 1.0", optional: true},
      {:gettext, "~> 0.26", optional: true},
      {:ecto_sql, "~> 3.12", optional: true},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end

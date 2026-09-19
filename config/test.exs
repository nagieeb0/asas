import Config

config :asas, ecto_repos: [Asas.TestRepo]

config :asas, Asas.TestRepo,
  username: System.get_env("PGUSER", "postgres"),
  password: System.get_env("PGPASSWORD", "postgres"),
  hostname: System.get_env("PGHOST", "localhost"),
  port: String.to_integer(System.get_env("PGPORT", "5432")),
  database: "asas_test",
  pool_size: 2

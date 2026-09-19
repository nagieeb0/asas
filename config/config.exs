import Config

# asas is a library and ships no runtime configuration. This file exists only so
# the test environment can stand up a real Postgres repo for Asas.Release, whose
# advisory-lock behaviour cannot be checked any other way. `priv/` and `config/`
# are both outside the `files` list in mix.exs, so neither reaches a consumer.
if config_env() == :test do
  import_config "test.exs"
end

import Config

config :phoenix, :json_library, JSON

if config_env() == :test do
  config :logger, level: :warning
  import_config "test.exs"
end

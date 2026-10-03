import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :retake, Retake.Repo,
  username: "postgres",
  password: "postgres",
  hostname: "127.0.0.1",
  database: "retake_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :retake, RetakeWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "ZVimAqcCKILNneo6+JCLQpTSJ2MVwOCKCKyqWNyjodrTzwVq5+CiB2IjNlzEfgeE",
  server: false

# Adapters available to the provider layer in tests (see Retake.Providers.Adapters).
config :retake, adapters: %{"fake" => Retake.Test.FakeAdapter}

# Tests run the debug renderer (`cargo build -p retake_render`, done by `just test`).
config :retake, renderer_bin: Path.expand("../../target/debug/retake_render", __DIR__)

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

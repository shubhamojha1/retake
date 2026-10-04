# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :retake,
  ecto_repos: [Retake.Repo],
  generators: [timestamp_type: :utc_datetime],
  # The renderer is a separate program run as a Port (decision D4). The release build
  # is the default; test.exs points at the debug build; RETAKE_RENDERER_BIN overrides
  # all of them (runtime.exs).
  renderer_bin: Path.expand("../../target/release/retake_render", __DIR__),
  # Video jobs (Retake.Videos.Runner): the providers file, and where finished MP4s go.
  providers_config: Path.expand("../../config/providers.toml", __DIR__),
  output_dir: Path.expand("../../.retake/out", __DIR__)

# Configure the endpoint
config :retake, RetakeWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: RetakeWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Retake.PubSub,
  live_view: [signing_salt: "ZPHt6QDg"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :whispr_calls,
  ecto_repos: [WhisprCalls.Repo],
  generators: [timestamp_type: :utc_datetime, binary_id: true]

# PromEx: we only run the plug-backed /metrics endpoint, dashboards and the
# standalone metrics HTTP server are disabled.
config :whispr_calls, WhisprCalls.PromEx,
  manual_metrics_start_delay: :no_delay,
  drop_metrics_groups: [],
  grafana: :disabled,
  metrics_server: :disabled

# Configure the endpoint
config :whispr_calls, WhisprCallsWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: WhisprCallsWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: WhisprCalls.PubSub,
  live_view: [signing_salt: "z1qS+htC"]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Tesla adapter: joken_jwks uses Tesla to fetch the auth-service JWKS.
# Pin the adapter to hackney so we don't silently fall back to :httpc.
config :tesla, adapter: Tesla.Adapter.Hackney

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

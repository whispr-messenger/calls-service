import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/whispr_calls start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :whispr_calls, WhisprCallsWeb.Endpoint, server: true
end

# Mirror the compile-time env into application config so runtime code
# (e.g. fail-closed checks in controllers) can branch on it without
# pulling Mix at runtime.
config :whispr_calls, env: config_env()

config :whispr_calls, WhisprCallsWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Redis connection URL: prefer a full REDIS_URL, otherwise compose REDIS_HOST
# + REDIS_PORT (used by the docker test stack and the Kubernetes manifests).
config :whispr_calls,
  redis_url:
    System.get_env("REDIS_URL") ||
      "redis://#{System.get_env("REDIS_HOST", "localhost")}:#{System.get_env("REDIS_PORT", "6379")}"

# LiveKit webhook secret (HMAC verification on /calls/webhooks/livekit).
# Required when the Phoenix server boots in prod (controller fails-closed
# with 503 if missing). Skipped for `eval` tasks (e.g. Release.migrate()
# which runs from the same image without PHX_SERVER set).
if config_env() == :prod and System.get_env("PHX_SERVER") do
  config :whispr_calls,
    livekit_webhook_secret:
      System.get_env("LIVEKIT_WEBHOOK_SECRET") ||
        raise("""
        environment variable LIVEKIT_WEBHOOK_SECRET is missing.
        It must match the webhook secret configured on the LiveKit server
        so we can verify signed webhooks instead of accepting spoofed events.
        """)
else
  if secret = System.get_env("LIVEKIT_WEBHOOK_SECRET") do
    config :whispr_calls, livekit_webhook_secret: secret
  end
end

# LiveKit API credentials + SFU URL consumed by
# `WhisprCalls.Calls.LiveKitClientHTTP` (create_room / delete_room / token
# generation). Without these the controller raises `ArgumentError` on the
# first authenticated POST /calls.
if key = System.get_env("LIVEKIT_API_KEY") do
  config :whispr_calls, livekit_api_key: key
end

if secret = System.get_env("LIVEKIT_API_SECRET") do
  config :whispr_calls, livekit_api_secret: secret
end

if url = System.get_env("LIVEKIT_API_URL") do
  config :whispr_calls, livekit_api_url: url
end

# Public WSS URL returned to clients in `create_call`. Defaults to the
# placeholder `wss://livekit.whispr.local` when unset; set this so mobile
# clients can reach the SFU.
if public_url = System.get_env("LIVEKIT_PUBLIC_URL") do
  config :whispr_calls, livekit_public_url: public_url
end

if config_env() == :prod do
  database_url =
    System.get_env("DATABASE_URL") ||
      raise """
      environment variable DATABASE_URL is missing.
      For example: ecto://USER:PASS@HOST/DATABASE
      """

  maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

  config :whispr_calls, WhisprCalls.Repo,
    # ssl: true,
    url: database_url,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
    # For machines with several cores, consider starting multiple pools of `pool_size`
    # pool_count: 4,
    socket_options: maybe_ipv6

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :whispr_calls, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :whispr_calls, WhisprCallsWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :whispr_calls, WhisprCallsWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :whispr_calls, WhisprCallsWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # JWKS URL used by the JWT authenticate plug to verify tokens issued by
  # the auth-service. The strategy module (WhisprCalls.JwksStrategy) reads
  # this at runtime.
  config :whispr_calls,
    jwks_url: System.fetch_env!("JWT_JWKS_URL")

  # Wire the HTTP messaging client when the Phoenix server boots in prod so
  # conversation-membership checks actually hit messaging-service. The
  # default Stub returns `{:ok, :member}` unconditionally, which would let
  # any authenticated user create a call in any conversation. Gated on
  # PHX_SERVER so `eval` tasks (e.g. Release.migrate()) don't require
  # these vars at boot.
  if System.get_env("PHX_SERVER") do
    config :whispr_calls,
      messaging_client: WhisprCalls.Grpc.MessagingClient.HTTP,
      messaging_http_endpoint: System.fetch_env!("MESSAGING_HTTP_ENDPOINT"),
      messaging_service_token: System.fetch_env!("MESSAGING_SERVICE_TOKEN")
  end
end

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

# WebSocket origin check (WHISPR-1354). En prod on resoud via MFA pour
# whitelister CORS_ALLOWED_ORIGINS au lieu de garder le `false` permissif
# herite de dev. Le risque sinon : un site tiers peut initier des appels
# LiveKit cross-origin si un user authentifie visite la page.
if config_env() == :prod do
  config :whispr_calls, WhisprCallsWeb.Endpoint,
    check_origin: {WhisprCallsWeb.Endpoint, :ws_check_origin, []}
end

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
  # fail-loud sur env critique au boot, peu importe PHX_SERVER. Migration-only
  # pods, IEx et health probe containers doivent aussi crash plutot que de
  # booter avec un secret_key_base nil silencieux.
  secret_key_base = System.fetch_env!("SECRET_KEY_BASE")

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

  # Web-server-only configuration: JWKS URL (consumed by the JWT plug on
  # incoming HTTP requests) and the HTTP messaging client (used by the
  # /calls controller for conversation membership checks). Gated on
  # PHX_SERVER so `eval` tasks (e.g. Release.migrate()) running from the
  # same image don't require these vars at boot.
  if System.get_env("PHX_SERVER") do
    config :whispr_calls,
      jwks_url: System.fetch_env!("JWT_JWKS_URL"),
      messaging_client: WhisprCalls.Grpc.MessagingClient.HTTP,
      messaging_http_endpoint: System.fetch_env!("MESSAGING_HTTP_ENDPOINT"),
      messaging_service_token: System.fetch_env!("MESSAGING_SERVICE_TOKEN")

    # Validation optionnelle de iss / aud sur les JWT entrants. Si auth-service
    # emet ces claims, les enforcer ici evite qu un token destine a un autre
    # service (ex: media) soit accepte par calls-service.
    if iss = System.get_env("JWT_EXPECTED_ISSUER") do
      config :whispr_calls, jwt_expected_issuer: iss
    end

    if aud = System.get_env("JWT_EXPECTED_AUDIENCE") do
      config :whispr_calls, jwt_expected_audience: aud
    end
  end
end

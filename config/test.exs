import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :whispr_calls, WhisprCalls.Repo,
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "5432")),
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  database:
    System.get_env(
      "DATABASE_NAME",
      "whispr_calls_test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size:
    String.to_integer(System.get_env("DATABASE_POOL_SIZE", "#{System.schedulers_online() * 2}"))

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :whispr_calls, WhisprCallsWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "krMz6zrvCKT7XekiNeN2CPCh9YR3NHlf2a7gD9/R76gdsIzGCH1x2SirLzARJ3oJ",
  server: false

# JWT signer used by authenticate plug in test env.
# Stored as {algorithm, secret} and materialised into a Joken.Signer lazily
# (Joken is not loaded at config-compile time).
config :whispr_calls, jwt_signer: {"HS256", "test_secret"}

# LiveKit configuration used by the Calls context in tests. The HTTP impl
# is never invoked (LiveKitClientMock takes over), but the public URL is
# embedded into the response so clients know where to connect.
config :whispr_calls, livekit_public_url: "wss://livekit.test"

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

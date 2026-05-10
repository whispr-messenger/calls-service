import Config

# Force using SSL in production. This also sets the "strict-security-transport" header,
# known as HSTS. If you have a health check endpoint, you may want to exclude it below.
# Note `:force_ssl` is required to be set at compile-time.
config :whispr_calls, WhisprCallsWeb.Endpoint,
  force_ssl: [
    # HSTS un an pour que les navigateurs refusent toute connexion en clair.
    # Sans `expires`, le header est envoye avec max-age=0 (no-op cote browser).
    hsts: true,
    expires: 31_536_000,
    rewrite_on: [:x_forwarded_proto],
    exclude: [
      # Le kubelet sonde en HTTP depuis le noeud - exempter les probes evite
      # les redirects 301 parasites dans les logs toutes les 10 s (WHISPR-1442).
      paths: ["/health/live", "/health/ready"],
      hosts: ["localhost", "127.0.0.1"]
    ]
  ]

# Do not print debug messages in production
config :logger, level: :info

# Use the JWKS strategy to verify tokens issued by the auth-service in prod.
# The JwksStrategy module must be started in the supervision tree (see
# WhisprCalls.Application); this line just tells the Authenticate plug and
# the user socket which signer to pick at verify-time.
config :whispr_calls, :jwt_signer, WhisprCalls.JwksStrategy

# Runtime production configuration, including reading
# of environment variables, is done on config/runtime.exs.

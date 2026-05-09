defmodule WhisprCalls.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Fail-fast: refuser de booter en prod si :messaging_client n est pas
    # configure. Sinon le default tomberait sur le Stub qui renvoie
    # {:ok, :member} pour tout le monde => privilege escalation silencieuse.
    assert_messaging_client_configured!()

    children =
      [
        WhisprCallsWeb.Telemetry,
        WhisprCalls.Repo,
        {DNSCluster, query: Application.get_env(:whispr_calls, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: WhisprCalls.PubSub},
        {Redix,
         {Application.get_env(:whispr_calls, :redis_url, "redis://localhost:6379"),
          [name: :redix]}},
        # PromEx metrics collector (Prometheus scrape at /metrics via plug).
        WhisprCalls.PromEx
      ] ++
        jwks_children() ++
        workers() ++
        [
          # Start to serve requests, typically the last entry
          WhisprCallsWeb.Endpoint
        ]

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: WhisprCalls.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Background workers are skipped in :test so the SQL sandbox doesn't fight
  # with a ticking worker that would check out connections on its own.
  defp workers do
    if Application.get_env(:whispr_calls, :start_background_workers?, true) do
      [WhisprCalls.Workers.RingingTimeoutWorker, WhisprCalls.Workers.RoomReconciler]
    else
      []
    end
  end

  # JwksStrategy is a JokenJwks GenServer that caches the auth-service public
  # keys. Only start it when the authenticate plug actually points at it
  # (prod). In test/dev the signer is an inline HS256 secret.
  defp jwks_children do
    case Application.get_env(:whispr_calls, :jwt_signer) do
      WhisprCalls.JwksStrategy -> [WhisprCalls.JwksStrategy]
      _ -> []
    end
  end

  # En prod le Stub fail-open n est jamais acceptable: il renverrait
  # {:ok, :member} pour n importe quelle paire (user, conversation) et
  # contournerait la verification de membership. On exige une impl explicite
  # (typiquement WhisprCalls.Grpc.MessagingClient.HTTP wired en runtime.exs).
  defp assert_messaging_client_configured! do
    if Application.get_env(:whispr_calls, :env) == :prod do
      case Application.get_env(:whispr_calls, :messaging_client) do
        nil ->
          raise """
          :messaging_client is not configured in production.
          Set it in config/runtime.exs (e.g. WhisprCalls.Grpc.MessagingClient.HTTP)
          before serving traffic. Without this, conversation membership checks
          would silently pass for every user (privilege escalation).
          """

        WhisprCalls.Grpc.MessagingClient.Stub ->
          raise """
          :messaging_client is set to the Stub in production.
          The Stub returns {:ok, :member} for everyone and must never be used
          outside :dev / :test. Use WhisprCalls.Grpc.MessagingClient.HTTP.
          """

        _ ->
          :ok
      end
    end
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WhisprCallsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

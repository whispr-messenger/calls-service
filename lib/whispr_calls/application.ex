defmodule WhisprCalls.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
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
      [WhisprCalls.Workers.RingingTimeoutWorker]
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

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    WhisprCallsWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

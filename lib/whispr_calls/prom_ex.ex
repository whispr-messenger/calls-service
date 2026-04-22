defmodule WhisprCalls.PromEx do
  @moduledoc """
  Prometheus metrics configuration for calls-service.

  Exposes the default PromEx plugin set (Application, BEAM, Phoenix, Ecto).
  Metrics are scraped via the `PromEx.Plug` mounted on the endpoint.

  The Grafana dashboards and the internal metrics server are disabled for
  now: Prometheus scrapes `/metrics` directly, dashboards are provisioned
  on the observability cluster side.
  """

  use PromEx, otp_app: :whispr_calls

  alias PromEx.Plugins

  @impl true
  def plugins do
    [
      Plugins.Application,
      Plugins.Beam,
      {Plugins.Phoenix, router: WhisprCallsWeb.Router, endpoint: WhisprCallsWeb.Endpoint},
      Plugins.Ecto
    ]
  end

  @impl true
  def dashboards do
    [
      {:prom_ex, "application.json"},
      {:prom_ex, "beam.json"},
      {:prom_ex, "phoenix.json"},
      {:prom_ex, "ecto.json"}
    ]
  end

  @impl true
  def dashboard_assigns, do: [datasource_id: "Prometheus"]
end

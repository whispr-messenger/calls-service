defmodule WhisprCallsWeb.HealthController do
  @moduledoc """
  Liveness and readiness probes. `live` always returns `200 ok`, `ready`
  checks database and Redis connectivity and returns `503` when any check
  fails.
  """
  use WhisprCallsWeb, :controller

  alias Ecto.Adapters.SQL, as: EctoSQL

  def live(conn, _params), do: json(conn, %{status: "ok"})

  def ready(conn, _params) do
    checks = [{:db, check_db()}, {:redis, check_redis()}]
    failed = Enum.filter(checks, fn {_, v} -> v != :ok end)

    if Enum.empty?(failed) do
      json(conn, %{status: "ready"})
    else
      conn
      |> put_status(503)
      |> json(%{status: "not_ready", failed: Enum.map(failed, fn {k, _} -> k end)})
    end
  end

  defp check_db do
    case EctoSQL.query(WhisprCalls.Repo, "SELECT 1") do
      {:ok, _} -> :ok
      {:error, _} -> :error
    end
  rescue
    _ -> :error
  end

  defp check_redis do
    case Redix.command(:redix, ["PING"]) do
      {:ok, "PONG"} -> :ok
      _ -> :error
    end
  rescue
    _ -> :error
  end
end

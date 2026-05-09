defmodule WhisprCallsWeb.Plugs.RateLimitCallCreation do
  @moduledoc """
  Bride la creation d appels a 5/min/user pour eviter le flood de
  notifications push + l explosion de la facture LiveKit en cas de boucle
  client buggee ou d attaquant avec un token valide (WHISPR-1363).

  Place dans le pipeline APRES `WhisprCallsWeb.Plugs.Authenticate` pour
  pouvoir indexer le bucket Hammer sur `current_user_id`. Si le plug est
  branche avant l auth (ou si l auth a fail sans halt), on degrade en
  401 plutot qu en accept silencieux.

  Le compteur reset 60 secondes apres la premiere creation observee
  dans la fenetre. Sur 429, on logge un warning structure pour audit.
  """

  import Plug.Conn
  require Logger

  @behaviour Plug

  # Fenetre glissante de comptage (en ms) et plafond. 5 appels/minute
  # couvre largement l usage legitime (un user qui rappelle apres 3
  # raccroches successifs reste sous la limite).
  @window_ms 60_000
  @max_calls 5

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{assigns: %{current_user_id: user_id}} = conn, _opts)
      when is_binary(user_id) do
    case Hammer.check_rate("call_create:#{user_id}", @window_ms, @max_calls) do
      {:allow, _count} ->
        conn

      {:deny, limit} ->
        # Format string-only pour ne pas dependre de la config :logger metadata.
        # On garde un prefixe stable "rate_limit_exceeded" pour qu un grep CI
        # ou une regle Loki puisse alerter sur la signature.
        Logger.warning(
          "rate_limit_exceeded plug=RateLimitCallCreation user_id=#{user_id} " <>
            "limit=#{limit} window_ms=#{@window_ms}"
        )

        too_many_requests(conn)
    end
  end

  # current_user_id absent : Authenticate aurait du halt avant nous.
  # Fail-closed : on refuse plutot que de skip silencieusement.
  def call(conn, _opts), do: unauthorized(conn)

  defp too_many_requests(conn) do
    body = ~s({"error":"rate_limit_exceeded"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(429, body)
    |> halt()
  end

  defp unauthorized(conn) do
    body = ~s({"error":"unauthorized"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end

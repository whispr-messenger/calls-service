defmodule WhisprCallsWeb.LiveKitWebhookController do
  @moduledoc """
  Receives LiveKit server webhooks (participant_left, room_finished, ...)
  and forwards them to the Calls context.

  Signature verification: LiveKit signs webhook bodies as a JWT using the
  configured API secret. The token is sent in the `Authorization` header
  and its `sha256` claim is the base64 digest of the raw body. The shared
  secret comes from `:livekit_webhook_secret` in the application env.

  Fail-closed policy: in `:prod` we refuse the request with HTTP 503 if the
  secret is missing or empty, so a misconfigured deployment cannot accept
  spoofed `participant_left` / `room_finished` events. In `:dev` and
  `:test` we keep accepting unsigned requests when the secret is unset for
  developer convenience.
  """
  use WhisprCallsWeb, :controller
  alias WhisprCalls.Calls
  require Logger

  @raw_body_key :livekit_raw_body

  def handle(conn, params) do
    with :ok <- verify_signature(conn),
         :ok <- process_event(params) do
      send_resp(conn, 200, "")
    else
      {:error, :invalid_signature} ->
        send_resp(conn, 401, "")

      {:error, :webhook_misconfigured} ->
        Logger.error(
          "livekit webhook rejected: LIVEKIT_WEBHOOK_SECRET is missing or empty in prod"
        )

        send_resp(conn, 503, "")

      {:error, reason} ->
        Logger.error("livekit webhook failed: #{inspect(reason)}")
        send_resp(conn, 500, "")
    end
  end

  defp verify_signature(conn) do
    case Application.get_env(:whispr_calls, :livekit_webhook_secret) do
      secret when is_binary(secret) and secret != "" ->
        verify_hmac(conn, secret)

      _missing_or_empty ->
        if Application.get_env(:whispr_calls, :env) == :prod do
          {:error, :webhook_misconfigured}
        else
          :ok
        end
    end
  end

  defp verify_hmac(conn, secret) do
    with [auth] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, body} <- fetch_raw_body(conn),
         {:ok, claims} <- verify_token(auth, secret),
         :ok <- match_body_hash(claims, body) do
      :ok
    else
      _ -> {:error, :invalid_signature}
    end
  end

  defp fetch_raw_body(conn) do
    case conn.assigns[@raw_body_key] do
      body when is_binary(body) -> {:ok, body}
      _ -> {:error, :no_raw_body}
    end
  end

  defp verify_token(token, secret) do
    signer = Joken.Signer.create("HS256", secret)
    Joken.verify_and_validate(%{}, token, signer)
  end

  defp match_body_hash(%{"sha256" => expected}, body) when is_binary(expected) do
    actual = :crypto.hash(:sha256, body) |> Base.encode64()
    if Plug.Crypto.secure_compare(expected, actual), do: :ok, else: {:error, :hash_mismatch}
  end

  defp match_body_hash(_, _), do: {:error, :hash_missing}

  defp process_event(%{
         "event" => "participant_left",
         "room" => %{"name" => room_name},
         "participant" => %{"identity" => user_id}
       }) do
    Calls.handle_participant_left(room_name, user_id) |> normalize_result()
  end

  defp process_event(%{"event" => "room_finished", "room" => %{"name" => room_name}}) do
    Calls.handle_room_finished(room_name) |> normalize_result()
  end

  defp process_event(_other), do: :ok

  defp normalize_result({:ok, _}), do: :ok
  defp normalize_result(:ok), do: :ok
  # Webhooks for rooms we don't know about (already cleaned up / unknown)
  # shouldn't make LiveKit retry; treat them as a no-op.
  defp normalize_result({:error, :not_found}), do: :ok
  defp normalize_result({:error, :not_invited}), do: :ok
  defp normalize_result({:error, _} = e), do: e
end

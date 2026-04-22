defmodule WhisprCallsWeb.LiveKitWebhookController do
  @moduledoc """
  Receives LiveKit server webhooks (participant_left, room_finished, ...)
  and forwards them to the Calls context.

  Signature verification: LiveKit signs webhook bodies as a JWT using the
  configured API secret. The token is sent in the `Authorization` header
  and its `sha256` claim is the base64 digest of the raw body. When
  `:livekit_webhook_secret` is set in the application env we verify the
  JWT using the shared secret and reject unmatched bodies. When it is not
  set (dev / early prod while WHISPR-1094 phase 7 rolls out) we accept
  everything – this matches the behaviour before the verification was
  implemented.
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

      {:error, reason} ->
        Logger.error("livekit webhook failed: #{inspect(reason)}")
        send_resp(conn, 500, "")
    end
  end

  defp verify_signature(conn) do
    case Application.get_env(:whispr_calls, :livekit_webhook_secret) do
      nil -> :ok
      "" -> :ok
      secret when is_binary(secret) -> verify_hmac(conn, secret)
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

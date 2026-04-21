defmodule WhisprCallsWeb.LiveKitWebhookController do
  @moduledoc """
  Receives LiveKit server webhooks (participant_left, room_finished, ...)
  and forwards them to the Calls context. Signature verification is a
  stub in dev; production must validate the HMAC signed by
  `LIVEKIT_WEBHOOK_SECRET`.
  """
  use WhisprCallsWeb, :controller
  alias WhisprCalls.Calls
  require Logger

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

  # TODO: validate HMAC once LIVEKIT_WEBHOOK_SECRET is provisioned.
  defp verify_signature(_conn), do: :ok

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

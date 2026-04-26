defmodule WhisprCallsWeb.CallChannel do
  @moduledoc """
  Per-call signaling topic. Only participants of the call can join. Clients
  push `mute` / `camera_off` events which are broadcasted to the other
  participants so the UI can reflect peer state without waiting for
  LiveKit metadata updates.
  """
  use WhisprCallsWeb, :channel
  alias WhisprCalls.Calls

  @impl true
  def join("call:" <> call_id, _params, socket) do
    user_id = socket.assigns.current_user_id

    case Calls.get_call_if_participant(call_id, user_id) do
      {:ok, _call} -> {:ok, socket}
      {:error, :not_found} -> {:error, %{reason: "forbidden"}}
    end
  end

  @impl true
  def handle_in("mute", %{"muted" => muted}, socket) when is_boolean(muted) do
    broadcast!(socket, "participant_muted", %{
      user_id: socket.assigns.current_user_id,
      muted: muted
    })

    {:noreply, socket}
  end

  def handle_in("mute", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  def handle_in("camera_off", %{"off" => off}, socket) when is_boolean(off) do
    broadcast!(socket, "participant_camera_off", %{
      user_id: socket.assigns.current_user_id,
      off: off
    })

    {:noreply, socket}
  end

  def handle_in("camera_off", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_payload"}}, socket}
  end

  # Catch-all: an unknown event must not crash the channel process and
  # disconnect the client. Silently ignore.
  def handle_in(_event, _payload, socket), do: {:noreply, socket}
end

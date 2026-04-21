defmodule WhisprCallsWeb.UserChannel do
  @moduledoc """
  Per-user topic. Used to push events that the user cares about regardless
  of which call they are currently in (e.g. "incoming call"). A user is
  only allowed to subscribe to their own topic.
  """
  use WhisprCallsWeb, :channel

  @impl true
  def join("user:" <> user_id, _params, socket) do
    if socket.assigns.current_user_id == user_id do
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end
end

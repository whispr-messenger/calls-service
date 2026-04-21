defmodule WhisprCallsWeb.CallController do
  @moduledoc """
  REST endpoints for call management: create (initiate), accept, decline,
  end, list and show. Error tuples bubble up to
  `WhisprCallsWeb.FallbackController` for standardized JSON responses.
  """
  use WhisprCallsWeb, :controller
  alias WhisprCalls.Calls

  action_fallback WhisprCallsWeb.FallbackController

  def create(conn, params) do
    user_id = conn.assigns.current_user_id
    conv_id = params["conversation_id"]

    attrs = %{
      type: params["type"] || "video",
      participant_ids: params["participant_ids"] || []
    }

    with {:ok, conv_id} <- validate_uuid(conv_id),
         {:ok, call, tokens} <- Calls.initiate_call(user_id, conv_id, attrs) do
      conn
      |> put_status(:created)
      |> json(%{
        call_id: call.id,
        status: call.status,
        livekit_token: tokens.token,
        livekit_url: tokens.url
      })
    end
  end

  def accept(conn, %{"id" => call_id}) do
    user_id = conn.assigns.current_user_id

    with {:ok, _call, tokens} <- Calls.accept_call(call_id, user_id) do
      json(conn, %{livekit_token: tokens.token, livekit_url: tokens.url})
    end
  end

  def decline(conn, %{"id" => call_id}) do
    user_id = conn.assigns.current_user_id

    with {:ok, _call} <- Calls.decline_call(call_id, user_id) do
      send_resp(conn, 204, "")
    end
  end

  def end_call(conn, %{"id" => call_id}) do
    user_id = conn.assigns.current_user_id

    with {:ok, _call} <- Calls.end_call(call_id, user_id) do
      send_resp(conn, 204, "")
    end
  end

  def index(conn, params) do
    user_id = conn.assigns.current_user_id
    filters = normalize_filters(params)
    calls = Calls.list_user_calls(user_id, filters)
    json(conn, %{data: Enum.map(calls, &serialize/1)})
  end

  def show(conn, %{"id" => id}) do
    user_id = conn.assigns.current_user_id

    with {:ok, call} <- Calls.get_call_if_participant(id, user_id) do
      json(conn, serialize(call))
    end
  end

  defp validate_uuid(nil), do: {:error, :invalid_request}

  defp validate_uuid(s) when is_binary(s) do
    case Ecto.UUID.cast(s) do
      {:ok, v} -> {:ok, v}
      :error -> {:error, :invalid_request}
    end
  end

  defp validate_uuid(_), do: {:error, :invalid_request}

  defp normalize_filters(params) do
    Enum.reduce([:status, :conversation_id, :limit], %{}, fn key, acc ->
      case params[Atom.to_string(key)] do
        nil -> acc
        v when key == :limit and is_binary(v) -> Map.put(acc, :limit, String.to_integer(v))
        v -> Map.put(acc, key, v)
      end
    end)
  end

  defp serialize(call) do
    %{
      id: call.id,
      initiator_id: call.initiator_id,
      conversation_id: call.conversation_id,
      type: call.type,
      status: call.status,
      started_at: call.started_at,
      connected_at: call.connected_at,
      ended_at: call.ended_at,
      duration_seconds: call.duration_seconds
    }
  end
end

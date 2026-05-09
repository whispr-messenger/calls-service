defmodule WhisprCalls.Calls.LiveKitClient do
  @moduledoc false
  @callback create_room(room_name :: String.t(), opts :: keyword) :: {:ok, map} | {:error, term}
  @callback delete_room(room_name :: String.t()) :: :ok | {:error, term}
  @callback generate_access_token(
              user_id :: String.t(),
              room_name :: String.t(),
              opts :: keyword
            ) ::
              {:ok, String.t()} | {:error, term}
  @callback revoke_participant(room_name :: String.t(), user_id :: String.t()) ::
              :ok | {:error, term}

  def create_room(room, opts), do: impl().create_room(room, opts)
  def delete_room(room), do: impl().delete_room(room)
  def generate_access_token(uid, room, opts), do: impl().generate_access_token(uid, room, opts)
  def revoke_participant(room, uid), do: impl().revoke_participant(room, uid)

  defp impl,
    do: Application.get_env(:whispr_calls, :livekit_client, WhisprCalls.Calls.LiveKitClientHTTP)
end

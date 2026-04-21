defmodule WhisprCalls.Calls.LiveKitClientHTTP do
  @moduledoc false
  @behaviour WhisprCalls.Calls.LiveKitClient

  @impl true
  def create_room(name, opts) do
    api_key = Application.fetch_env!(:whispr_calls, :livekit_api_key)
    api_secret = Application.fetch_env!(:whispr_calls, :livekit_api_secret)
    api_url = Application.fetch_env!(:whispr_calls, :livekit_api_url)

    token = admin_token(api_key, api_secret)

    body = %{
      name: name,
      empty_timeout: 30,
      max_participants: Keyword.get(opts, :max_participants, 20)
    }

    api_url
    |> Kernel.<>("/twirp/livekit.RoomService/CreateRoom")
    |> Req.post(
      headers: [{"authorization", "Bearer " <> token}],
      json: body
    )
    |> parse_response()
  end

  @impl true
  def delete_room(name) do
    api_key = Application.fetch_env!(:whispr_calls, :livekit_api_key)
    api_secret = Application.fetch_env!(:whispr_calls, :livekit_api_secret)
    api_url = Application.fetch_env!(:whispr_calls, :livekit_api_url)

    token = admin_token(api_key, api_secret)

    case Req.post(api_url <> "/twirp/livekit.RoomService/DeleteRoom",
           headers: [{"authorization", "Bearer " <> token}],
           json: %{room: name}
         ) do
      {:ok, %{status: 200}} -> :ok
      other -> {:error, other}
    end
  end

  @impl true
  def generate_access_token(user_id, room_name, opts) do
    api_key = Application.fetch_env!(:whispr_calls, :livekit_api_key)
    api_secret = Application.fetch_env!(:whispr_calls, :livekit_api_secret)
    ttl_seconds = Keyword.get(opts, :ttl, 7200)

    claims = %{
      "iss" => api_key,
      "sub" => user_id,
      "nbf" => System.system_time(:second),
      "exp" => System.system_time(:second) + ttl_seconds,
      "video" => %{
        "room" => room_name,
        "roomJoin" => true,
        "canPublish" => true,
        "canSubscribe" => true
      }
    }

    signer = Joken.Signer.create("HS256", api_secret)

    case Joken.encode_and_sign(claims, signer) do
      {:ok, token, _} -> {:ok, token}
      err -> err
    end
  end

  defp admin_token(key, secret) do
    claims = %{
      "iss" => key,
      "sub" => key,
      "nbf" => System.system_time(:second),
      "exp" => System.system_time(:second) + 60,
      "video" => %{"roomAdmin" => true, "roomCreate" => true}
    }

    signer = Joken.Signer.create("HS256", secret)
    {:ok, token, _} = Joken.encode_and_sign(claims, signer)
    token
  end

  defp parse_response({:ok, %{status: 200, body: body}}), do: {:ok, body}
  defp parse_response(other), do: {:error, other}
end

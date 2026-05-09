defmodule WhisprCalls.Calls.LiveKitClientHTTP do
  @moduledoc false
  @behaviour WhisprCalls.Calls.LiveKitClient

  # TTL par defaut des access tokens LiveKit (en secondes).
  # 120s suffisent pour le join + handshake initial : une fois la session
  # WebRTC etablie, le client n a plus besoin de revalider le token cote SFU.
  # Avant on etait a 7200s (2h) ce qui laissait une fenetre d attaque enorme
  # si un token fuitait via logs / HAR / extension navigateur (WHISPR-1363).
  @default_ttl_seconds 120

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
    ttl_seconds = Keyword.get(opts, :ttl, @default_ttl_seconds)
    # role-gating pour eviter publish unauthorized (WHISPR-1409).
    # default :speaker preserve le comportement 1-1 et group call existant.
    role = Keyword.get(opts, :role, :speaker)

    video_grants =
      role
      |> role_permissions()
      |> Map.merge(%{"room" => room_name, "roomJoin" => true})

    claims = %{
      "iss" => api_key,
      "sub" => user_id,
      "nbf" => System.system_time(:second),
      "exp" => System.system_time(:second) + ttl_seconds,
      "video" => video_grants
    }

    signer = Joken.Signer.create("HS256", api_secret)

    case Joken.encode_and_sign(claims, signer) do
      {:ok, token, _} -> {:ok, token}
      err -> err
    end
  end

  # speaker = participant classique (peut publier audio/video et subscribe).
  defp role_permissions(:speaker),
    do: %{"canPublish" => true, "canSubscribe" => true}

  # listener = viewer seulement, ne peut pas inject d audio/video.
  defp role_permissions(:listener),
    do: %{"canPublish" => false, "canSubscribe" => true}

  # admin = moderation, peut publier des data messages et kick.
  defp role_permissions(:admin),
    do: %{
      "canPublish" => true,
      "canSubscribe" => true,
      "canPublishData" => true,
      "roomAdmin" => true
    }

  @impl true
  def revoke_participant(room_name, user_id) do
    # Force le kick d un participant cote LiveKit. Combine avec un TTL court
    # cote token (120s), ca evite qu un attaquant qui a sniff un token reste
    # connecte a la room apres end_call. Twirp endpoint RoomService.RemoveParticipant
    # attend {room, identity}. On considere 200 et 404 comme un succes
    # (404 = participant deja parti / room deja deletee).
    api_key = Application.fetch_env!(:whispr_calls, :livekit_api_key)
    api_secret = Application.fetch_env!(:whispr_calls, :livekit_api_secret)
    api_url = Application.fetch_env!(:whispr_calls, :livekit_api_url)

    token = admin_token(api_key, api_secret)

    case Req.post(api_url <> "/twirp/livekit.RoomService/RemoveParticipant",
           headers: [{"authorization", "Bearer " <> token}],
           json: %{room: room_name, identity: user_id}
         ) do
      {:ok, %{status: status}} when status in [200, 404] -> :ok
      other -> {:error, other}
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

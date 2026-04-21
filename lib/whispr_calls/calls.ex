defmodule WhisprCalls.Calls do
  @moduledoc """
  Context for call management: initiate, accept, decline and end calls.

  Wraps LiveKit room provisioning, participant tracking and Redis event
  publishing. The conversation-membership check is stubbed for now and will
  be wired to the messaging-service over gRPC in a follow-up.
  """

  import Ecto.Query, warn: false

  alias Ecto.Multi
  alias WhisprCalls.Calls.{Call, CallParticipant, LiveKitClient}
  alias WhisprCalls.Events.Publisher
  alias WhisprCalls.Repo

  @type uuid :: String.t()

  @doc """
  Starts a call: creates the LiveKit room, inserts the Call + participants,
  generates an access token for the initiator and publishes a Redis event
  so messaging-service can notify the other participants.
  """
  @spec initiate_call(uuid(), uuid(), map()) ::
          {:ok, Call.t(), %{token: String.t(), url: String.t()}}
          | {:error, atom() | Ecto.Changeset.t()}
  def initiate_call(initiator_id, conversation_id, %{} = attrs) do
    type = Map.get(attrs, :type, "audio")
    participant_ids = Map.get(attrs, :participant_ids, [])

    with {:ok, :member} <- verify_conversation_membership(initiator_id, conversation_id),
         room_name <- generate_room_name(),
         {:ok, _room} <- LiveKitClient.create_room(room_name, []),
         {:ok, %{call: call}} <-
           insert_call_with_participants(
             initiator_id,
             conversation_id,
             type,
             room_name,
             participant_ids
           ),
         {:ok, token} <- LiveKitClient.generate_access_token(initiator_id, room_name, []) do
      :ok =
        publish_initiated(call, initiator_id, conversation_id, type, room_name, participant_ids)

      {:ok, call, %{token: token, url: livekit_public_url()}}
    end
  end

  defp insert_call_with_participants(initiator_id, conversation_id, type, room_name, others) do
    now = DateTime.utc_now()

    call_attrs = %{
      initiator_id: initiator_id,
      conversation_id: conversation_id,
      type: type,
      livekit_room: room_name,
      status: "ringing",
      started_at: now
    }

    Multi.new()
    |> Multi.insert(:call, Call.changeset(%Call{}, call_attrs))
    |> Multi.run(:participants, fn repo, %{call: call} ->
      initiator_row = %{
        call_id: call.id,
        user_id: initiator_id,
        status: "joined",
        invited_at: now,
        joined_at: now
      }

      other_rows =
        Enum.map(others, fn uid ->
          %{
            call_id: call.id,
            user_id: uid,
            status: "invited",
            invited_at: now
          }
        end)

      rows = [initiator_row | other_rows]
      {count, _} = repo.insert_all(CallParticipant, rows)
      {:ok, count}
    end)
    |> Repo.transaction()
  end

  defp publish_initiated(call, initiator_id, conversation_id, type, room_name, participant_ids) do
    Publisher.publish("whispr:calls:initiated", %{
      call_id: call.id,
      initiator_id: initiator_id,
      conversation_id: conversation_id,
      type: type,
      livekit_room: room_name,
      participant_ids: participant_ids,
      started_at: DateTime.to_iso8601(call.started_at)
    })

    :ok
  rescue
    _ -> :ok
  end

  defp generate_room_name do
    "call_" <> (:crypto.strong_rand_bytes(12) |> Base.url_encode64(padding: false))
  end

  defp livekit_public_url do
    Application.get_env(:whispr_calls, :livekit_public_url, "wss://livekit.whispr.local")
  end

  # Stub until messaging-service gRPC client lands. Returns {:ok, :member}
  # unconditionally so the happy path works end-to-end in tests and dev.
  defp verify_conversation_membership(_user_id, _conversation_id), do: {:ok, :member}
end

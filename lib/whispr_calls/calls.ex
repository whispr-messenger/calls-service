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
  alias WhisprCalls.Grpc.MessagingClient
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

  @doc """
  Accepts a ringing call: flips the participant to joined, flips the call
  to connected (if first join), returns a LiveKit token for the user and
  publishes a Redis event.
  """
  @spec accept_call(uuid(), uuid()) ::
          {:ok, Call.t(), %{token: String.t(), url: String.t()}}
          | {:error, :not_invited | :call_not_found | term()}
  def accept_call(call_id, user_id) do
    with {:ok, call} <- fetch_call(call_id),
         {:ok, participant} <- fetch_participant(call_id, user_id),
         {:ok, %{call: updated_call}} <- mark_participant_joined(call, participant),
         {:ok, token} <- LiveKitClient.generate_access_token(user_id, call.livekit_room, []) do
      track_active_participant(updated_call, user_id)

      _ =
        Publisher.publish("whispr:calls:accepted", %{
          call_id: updated_call.id,
          user_id: user_id,
          accepted_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      {:ok, updated_call, %{token: token, url: livekit_public_url()}}
    end
  end

  @doc """
  Declines a ringing call: flips the participant status to `declined`.
  Publishes a Redis event so the initiator gets notified.
  """
  @spec decline_call(uuid(), uuid()) :: {:ok, Call.t()} | {:error, atom()}
  def decline_call(call_id, user_id) do
    with {:ok, call} <- fetch_call(call_id),
         {:ok, participant} <- fetch_participant(call_id, user_id),
         {:ok, _updated} <-
           participant
           |> CallParticipant.changeset(%{status: "declined"})
           |> Repo.update() do
      _ =
        Publisher.publish("whispr:calls:declined", %{
          call_id: call.id,
          user_id: user_id,
          declined_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      {:ok, call}
    end
  end

  @doc """
  A participant leaves the call. If they are the last active participant,
  the call transitions to `ended`, duration is computed and the LiveKit
  room is deleted.
  """
  @spec end_call(uuid(), uuid()) :: {:ok, Call.t()} | {:error, atom()}
  def end_call(call_id, user_id) do
    with {:ok, call} <- fetch_call(call_id),
         {:ok, participant} <- fetch_participant(call_id, user_id),
         {:ok, _updated} <-
           participant
           |> CallParticipant.changeset(%{status: "left", left_at: DateTime.utc_now()})
           |> Repo.update() do
      finalize_or_continue(call)
    end
  end

  defp finalize_or_continue(%Call{} = call) do
    if has_active_participants?(call.id) do
      {:ok, call}
    else
      finalize_call(call, "all_left")
    end
  end

  defp has_active_participants?(call_id) do
    Repo.exists?(
      from p in CallParticipant,
        where: p.call_id == ^call_id and p.status == "joined"
    )
  end

  defp finalize_call(%Call{} = call, reason) do
    now = DateTime.utc_now()
    duration = DateTime.diff(now, call.connected_at || call.started_at, :second)

    {:ok, updated} =
      call
      |> Call.changeset(%{
        status: "ended",
        ended_at: now,
        duration_seconds: duration,
        end_reason: reason
      })
      |> Repo.update()

    _ = LiveKitClient.delete_room(call.livekit_room)

    _ =
      Publisher.publish("whispr:calls:ended", %{
        call_id: updated.id,
        ended_at: DateTime.to_iso8601(now),
        duration_seconds: duration,
        end_reason: reason
      })

    {:ok, updated}
  end

  @doc """
  Returns calls in which `user_id` is a participant. Supports optional
  filters: `:status`, `:conversation_id`, `:limit` (default 50).
  Ordered by `started_at` desc.
  """
  @spec list_user_calls(uuid(), map()) :: [Call.t()]
  def list_user_calls(user_id, filters \\ %{}) do
    limit = Map.get(filters, :limit, 50)

    query =
      from c in Call,
        join: p in CallParticipant,
        on: p.call_id == c.id,
        where: p.user_id == ^user_id,
        order_by: [desc: c.started_at],
        limit: ^limit

    query
    |> maybe_filter_status(filters)
    |> maybe_filter_conversation(filters)
    |> Repo.all()
  end

  defp maybe_filter_status(query, %{status: status}) when is_binary(status) do
    from [c, _p] in query, where: c.status == ^status
  end

  defp maybe_filter_status(query, _), do: query

  defp maybe_filter_conversation(query, %{conversation_id: conv}) when is_binary(conv) do
    from [c, _p] in query, where: c.conversation_id == ^conv
  end

  defp maybe_filter_conversation(query, _), do: query

  @doc """
  Returns the call if `user_id` is one of its participants, otherwise
  `{:error, :not_found}`.
  """
  @spec get_call_if_participant(uuid(), uuid()) :: {:ok, Call.t()} | {:error, :not_found}
  def get_call_if_participant(call_id, user_id) do
    query =
      from c in Call,
        join: p in CallParticipant,
        on: p.call_id == c.id,
        where: c.id == ^call_id and p.user_id == ^user_id,
        limit: 1

    case Repo.one(query) do
      nil -> {:error, :not_found}
      %Call{} = call -> {:ok, call}
    end
  end

  @doc """
  Handles a `room_finished` webhook from LiveKit. Idempotent: does nothing
  if the call is already ended, otherwise finalizes it with end_reason
  `room_finished`.
  """
  @spec handle_room_finished(String.t()) :: {:ok, Call.t()} | {:error, :not_found}
  def handle_room_finished(livekit_room) when is_binary(livekit_room) do
    case Repo.get_by(Call, livekit_room: livekit_room) do
      nil -> {:error, :not_found}
      %Call{status: "ended"} = call -> {:ok, call}
      %Call{} = call -> finalize_call(call, "room_finished")
    end
  end

  @doc """
  Handles a `participant_left` webhook from LiveKit. Flips the participant
  status to `left` and finalizes the call when there is no one active left.
  """
  @spec handle_participant_left(String.t(), uuid()) :: {:ok, Call.t()} | {:error, atom()}
  def handle_participant_left(livekit_room, user_id)
      when is_binary(livekit_room) and is_binary(user_id) do
    case Repo.get_by(Call, livekit_room: livekit_room) do
      nil -> {:error, :not_found}
      %Call{} = call -> end_call(call.id, user_id)
    end
  end

  defp fetch_call(call_id) do
    case Repo.get(Call, call_id) do
      nil -> {:error, :call_not_found}
      %Call{} = call -> {:ok, call}
    end
  end

  defp fetch_participant(call_id, user_id) do
    case Repo.get_by(CallParticipant, call_id: call_id, user_id: user_id) do
      nil -> {:error, :not_invited}
      %CallParticipant{} = participant -> {:ok, participant}
    end
  end

  defp mark_participant_joined(%Call{} = call, %CallParticipant{} = participant) do
    now = DateTime.utc_now()

    Multi.new()
    |> Multi.update(
      :participant,
      CallParticipant.changeset(participant, %{
        status: "joined",
        joined_at: now
      })
    )
    |> Multi.update(
      :call,
      Call.changeset(call, call_connected_attrs(call, now))
    )
    |> Repo.transaction()
  end

  defp call_connected_attrs(%Call{status: "ringing"} = _call, now) do
    %{status: "connected", connected_at: now}
  end

  defp call_connected_attrs(%Call{} = _call, _now), do: %{}

  defp track_active_participant(%Call{livekit_room: room}, user_id) do
    case Redix.command(:redix, ["SADD", "calls:#{room}:participants", user_id]) do
      {:ok, _} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
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

  # Delegates to the configured messaging client to check whether the user
  # actually belongs to the conversation. In tests / dev the Stub returns
  # `{:ok, :member}` unconditionally; in prod the HTTP fallback (or, later,
  # the gRPC client) hits messaging-service.
  defp verify_conversation_membership(user_id, conversation_id) do
    MessagingClient.verify_membership(conversation_id, user_id)
  end
end

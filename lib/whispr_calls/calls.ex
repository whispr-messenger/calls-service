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
         :ok <- verify_invitees_are_members(conversation_id, participant_ids),
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
          | {:error,
             :not_invited
             | :call_not_found
             | :call_already_ended
             | :call_not_ringing
             | :participant_not_invited
             | term()}
  def accept_call(call_id, user_id) do
    # verrou FOR UPDATE pour serialiser les accept concurrents (group call)
    case Repo.transaction(accept_call_multi(call_id, user_id)) do
      {:ok, %{call: updated_call}} ->
        with {:ok, token} <-
               LiveKitClient.generate_access_token(user_id, updated_call.livekit_room, []) do
          track_active_participant(updated_call, user_id)

          _ =
            Publisher.publish("whispr:calls:accepted", %{
              call_id: updated_call.id,
              user_id: user_id,
              accepted_at: DateTime.to_iso8601(DateTime.utc_now())
            })

          {:ok, updated_call, %{token: token, url: livekit_public_url()}}
        end

      {:error, _step, reason, _changes} ->
        {:error, reason}
    end
  end

  # Construit la transaction qui pose un FOR UPDATE sur la row Call,
  # revalide le statut sous lock, charge le participant et applique les
  # updates dans la meme transaction. Garantit qu un seul accept passe le
  # call de "ringing" a "connected" sur un appel de groupe.
  defp accept_call_multi(call_id, user_id) do
    Multi.new()
    |> Multi.run(:locked_call, fn repo, _ ->
      case repo.get(Call, call_id, lock: "FOR UPDATE") do
        nil -> {:error, :call_not_found}
        %Call{} = call -> {:ok, call}
      end
    end)
    |> Multi.run(:check_ringing, fn _repo, %{locked_call: call} ->
      case ensure_call_ringing(call) do
        :ok -> {:ok, :ringing}
        err -> err
      end
    end)
    |> Multi.run(:participant, fn repo, _ ->
      case repo.get_by(CallParticipant, call_id: call_id, user_id: user_id) do
        nil -> {:error, :not_invited}
        %CallParticipant{} = p -> {:ok, p}
      end
    end)
    |> Multi.run(:check_invited, fn _repo, %{participant: p} ->
      case ensure_participant_invited(p) do
        :ok -> {:ok, :invited}
        err -> err
      end
    end)
    |> Multi.run(:joined, fn repo, %{participant: participant} ->
      now = DateTime.utc_now()

      with {:ok, _} <-
             participant
             |> CallParticipant.changeset(%{status: "joined", joined_at: now})
             |> repo.update() do
        {:ok, now}
      end
    end)
    |> Multi.run(:call, fn repo, %{locked_call: call, joined: now} ->
      call
      |> Call.changeset(call_connected_attrs(call, now))
      |> repo.update()
    end)
  end

  # Only a ringing call can be accepted or declined. Already-terminal statuses
  # (ended/missed/declined/failed) collapse to :call_already_ended so the
  # controller maps them to 410 Gone semantics, while in-progress statuses
  # (connected) yield :call_not_ringing for 409 Conflict.
  defp ensure_call_ringing(%Call{status: "ringing"}), do: :ok

  defp ensure_call_ringing(%Call{status: status})
       when status in ["ended", "missed", "declined", "failed"],
       do: {:error, :call_already_ended}

  defp ensure_call_ringing(_), do: {:error, :call_not_ringing}

  defp ensure_participant_invited(%CallParticipant{status: "invited"}), do: :ok
  defp ensure_participant_invited(_), do: {:error, :participant_not_invited}

  @doc """
  Declines a ringing call: flips the participant status to `declined`.
  Publishes a Redis event so the initiator gets notified.
  """
  @spec decline_call(uuid(), uuid()) :: {:ok, Call.t()} | {:error, atom()}
  def decline_call(call_id, user_id) do
    # verrou FOR UPDATE pour serialiser decline / accept concurrents.
    # Sans lock, un decline et un accept simultanes peuvent tous les deux
    # passer les guards sur un snapshot "ringing" stale et ecrire des
    # statuts contradictoires sur le participant.
    case Repo.transaction(decline_call_multi(call_id, user_id)) do
      {:ok, %{call: call}} -> {:ok, call}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp decline_call_multi(call_id, user_id) do
    Multi.new()
    |> Multi.run(:locked_call, fn repo, _ ->
      case repo.get(Call, call_id, lock: "FOR UPDATE") do
        nil -> {:error, :call_not_found}
        %Call{} = call -> {:ok, call}
      end
    end)
    |> Multi.run(:check_ringing, fn _repo, %{locked_call: call} ->
      case ensure_call_ringing(call) do
        :ok -> {:ok, :ringing}
        err -> err
      end
    end)
    |> Multi.run(:participant, fn repo, _ ->
      case repo.get_by(CallParticipant, call_id: call_id, user_id: user_id) do
        nil -> {:error, :not_invited}
        %CallParticipant{} = p -> {:ok, p}
      end
    end)
    |> Multi.run(:check_invited, fn _repo, %{participant: p} ->
      case ensure_participant_invited(p) do
        :ok -> {:ok, :invited}
        err -> err
      end
    end)
    |> Multi.run(:declined, fn repo, %{participant: participant} ->
      participant
      |> CallParticipant.changeset(%{status: "declined"})
      |> repo.update()
    end)
    |> Multi.run(:call, fn _repo, %{locked_call: call} ->
      _ =
        Publisher.publish("whispr:calls:declined", %{
          call_id: call.id,
          user_id: user_id,
          declined_at: DateTime.to_iso8601(DateTime.utc_now())
        })

      {:ok, call}
    end)
  end

  @doc """
  A participant leaves the call. If they are the last active participant,
  the call transitions to `ended`, duration is computed and the LiveKit
  room is deleted.
  """
  @spec end_call(uuid(), uuid()) :: {:ok, Call.t()} | {:error, atom()}
  def end_call(call_id, user_id) do
    # verrou FOR UPDATE pour serialiser les leave concurrents en groupe.
    # Sans lock, deux leaves quasi-simultanes peuvent observer un etat
    # intermediaire et soit double-finaliser (race vers all_left), soit
    # laisser le call en "connected" alors que plus personne n est actif.
    case Repo.transaction(end_call_multi(call_id, user_id)) do
      {:ok, %{result: {:ok, call}}} -> {:ok, call}
      {:ok, %{result: {:error, reason}}} -> {:error, reason}
      {:error, _step, reason, _changes} -> {:error, reason}
    end
  end

  defp end_call_multi(call_id, user_id) do
    Multi.new()
    |> Multi.run(:locked_call, fn repo, _ ->
      case repo.get(Call, call_id, lock: "FOR UPDATE") do
        nil -> {:error, :call_not_found}
        %Call{} = call -> {:ok, call}
      end
    end)
    |> Multi.run(:participant, fn repo, _ ->
      case repo.get_by(CallParticipant, call_id: call_id, user_id: user_id) do
        nil -> {:error, :not_invited}
        %CallParticipant{} = participant -> {:ok, participant}
      end
    end)
    |> Multi.run(:result, fn repo, %{locked_call: call, participant: participant} ->
      finalize_end_call_locked(repo, call, participant)
    end)
  end

  # Idempotent : si le call est deja "ended" (autre leave a deja finalise
  # sous le lock), on retourne {:ok, call} sans toucher au participant
  # ni republier d evenement.
  defp finalize_end_call_locked(_repo, %Call{status: "ended"} = call, _participant) do
    {:ok, {:ok, call}}
  end

  defp finalize_end_call_locked(repo, %Call{} = call, %CallParticipant{} = participant) do
    with {:ok, _updated} <-
           participant
           |> CallParticipant.changeset(%{status: "left", left_at: DateTime.utc_now()})
           |> repo.update() do
      _ = publish_participant_left(call, participant.user_id)
      {:ok, finalize_or_continue(repo, call)}
    end
  end

  # In a 1v1 call (initiator + 1 invitee), end the call as soon as ONE
  # participant leaves. Otherwise (group call), keep the call alive until
  # all active participants have left. This avoids the bug where peer B
  # remains stuck on the LiveKit room after peer A hangs up.
  #
  # Appele sous le lock FOR UPDATE de la row Call : les requetes
  # one_to_one?/any_participant_left?/has_active_participants? observent
  # un snapshot stable, plus de race d interleaving sur les leave groupe.
  defp finalize_or_continue(repo, %Call{} = call) do
    cond do
      one_to_one?(repo, call) and any_participant_left?(repo, call.id) ->
        finalize_call(call, "peer_left")

      has_active_participants?(repo, call.id) ->
        {:ok, call}

      true ->
        finalize_call(call, "all_left")
    end
  end

  defp has_active_participants?(repo, call_id) do
    repo.exists?(
      from p in CallParticipant,
        where: p.call_id == ^call_id and p.status == "joined"
    )
  end

  defp any_participant_left?(repo, call_id) do
    repo.exists?(
      from p in CallParticipant,
        where: p.call_id == ^call_id and p.status == "left"
    )
  end

  defp one_to_one?(repo, %Call{id: call_id, type: type}) when type in ["audio", "video"] do
    repo.aggregate(from(p in CallParticipant, where: p.call_id == ^call_id), :count) == 2
  end

  defp one_to_one?(_repo, _), do: false

  defp publish_participant_left(%Call{} = call, user_id) do
    Publisher.publish("whispr:calls:participant_left", %{
      call_id: call.id,
      conversation_id: call.conversation_id,
      user_id: user_id,
      left_at: DateTime.to_iso8601(DateTime.utc_now())
    })
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

    # Revoke explicite des tokens LiveKit avant de delete la room (WHISPR-1363).
    # Defense en profondeur : meme si un attaquant a sniff un token (TTL 120s),
    # on kick chaque participant cote SFU des qu un end_call est emis.
    # delete_room couvre normalement deja ce cas mais le revoke individuel
    # protege le narrow window entre le moment ou un peer leave et le moment
    # ou la room finalizes (group call avec un seul leave avant la fin).
    _ = revoke_all_participants(call)
    _ = LiveKitClient.delete_room(call.livekit_room)
    _ = cleanup_active_participants(call)

    _ =
      Publisher.publish("whispr:calls:ended", %{
        call_id: updated.id,
        ended_at: DateTime.to_iso8601(now),
        duration_seconds: duration,
        end_reason: reason
      })

    {:ok, updated}
  end

  # Iterates sur tous les participants connus du call pour les kick LiveKit.
  # Ignore les erreurs individuelles : on est dans le finalize, le delete_room
  # qui suit fait office de filet de securite.
  defp revoke_all_participants(%Call{id: call_id, livekit_room: room}) when is_binary(room) do
    CallParticipant
    |> where([p], p.call_id == ^call_id)
    |> select([p], p.user_id)
    |> Repo.all()
    |> Enum.each(fn user_id ->
      _ = LiveKitClient.revoke_participant(room, user_id)
    end)
  end

  defp revoke_all_participants(_), do: :ok

  # The Redis set `calls:{room}:participants` is populated by
  # `track_active_participant/2` on each accept. It's kept around for ad-hoc
  # debugging (who is currently in the room) but the lifecycle is bounded:
  # we drop the key here when the call is finalized so the keyspace doesn't
  # grow forever.
  defp cleanup_active_participants(%Call{livekit_room: room}) when is_binary(room) do
    case Redix.command(:redix, ["DEL", "calls:#{room}:participants"]) do
      {:ok, _} -> :ok
      _ -> :ok
    end
  rescue
    _ -> :ok
  end

  defp cleanup_active_participants(_), do: :ok

  @doc """
  Returns calls in which `user_id` is a participant. Supports optional
  filters: `:status`, `:conversation_id`, `:limit` (default 50),
  `:offset` (default 0). Ordered by `started_at` desc.

  The controller is responsible for clamping `:limit` and `:offset` to
  safe bounds before they reach this function.
  """
  @spec list_user_calls(uuid(), map()) :: [Call.t()]
  def list_user_calls(user_id, filters \\ %{}) do
    limit = Map.get(filters, :limit, 50)
    offset = Map.get(filters, :offset, 0)

    query =
      from c in Call,
        join: p in CallParticipant,
        on: p.call_id == c.id,
        where: p.user_id == ^user_id,
        order_by: [desc: c.started_at],
        limit: ^limit,
        offset: ^offset

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
    # FOR UPDATE pour eviter la double-finalisation si un end_call concurrent
    # (client DELETE ou webhook participant_left) arrive en meme temps.
    result =
      Repo.transaction(fn ->
        case Repo.get_by(Call, livekit_room: livekit_room) do
          nil ->
            {:error, :not_found}

          %Call{status: "ended"} = call ->
            {:ok, call}

          %Call{} = call ->
            locked = Repo.get(Call, call.id, lock: "FOR UPDATE")

            if locked.status == "ended" do
              {:ok, locked}
            else
              finalize_call(locked, "room_finished")
            end
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, reason} -> {:error, reason}
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

  # Validates that every invited participant actually belongs to the
  # conversation. Without this, a malicious client could make us ring users
  # who never opted into the conversation.
  #
  # Uses a single `list_members/1` round-trip rather than N
  # `verify_membership/2` calls. The Stub returns `{:ok, :any}` so dev/test
  # short-circuit to `:ok` without inspecting member IDs.
  defp verify_invitees_are_members(_conversation_id, []), do: :ok

  defp verify_invitees_are_members(conversation_id, participant_ids) do
    case MessagingClient.list_members(conversation_id) do
      {:ok, :any} ->
        :ok

      {:ok, members} when is_list(members) ->
        if MapSet.subset?(MapSet.new(participant_ids), MapSet.new(members)) do
          :ok
        else
          {:error, :invitee_not_member}
        end

      {:error, _} ->
        {:error, :invitee_not_member}
    end
  end
end

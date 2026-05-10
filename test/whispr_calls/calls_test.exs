defmodule WhisprCalls.CallsTest do
  use WhisprCalls.DataCase, async: false
  import Mox

  alias WhisprCalls.Calls
  alias WhisprCalls.Calls.{Call, CallParticipant, LiveKitClientMock}
  alias WhisprCalls.Repo

  setup :verify_on_exit!

  describe "initiate_call/3" do
    test "creates call + participants + returns livekit token" do
      initiator = Ecto.UUID.generate()
      conv = Ecto.UUID.generate()
      other = Ecto.UUID.generate()

      expect(LiveKitClientMock, :create_room, fn _name, _opts -> {:ok, %{}} end)

      expect(LiveKitClientMock, :generate_access_token, fn ^initiator, _room, _opts ->
        {:ok, "lk_token"}
      end)

      assert {:ok, call, %{token: "lk_token", url: _url}} =
               Calls.initiate_call(initiator, conv, %{
                 type: "video",
                 participant_ids: [other]
               })

      assert call.status == "ringing"
      assert call.type == "video"
      assert call.initiator_id == initiator

      participants = Repo.all(CallParticipant)
      assert length(participants) == 2
      assert Enum.any?(participants, &(&1.user_id == initiator and &1.status == "joined"))
      assert Enum.any?(participants, &(&1.user_id == other and &1.status == "invited"))
    end

    test "returns :not_member when messaging-service rejects the initiator" do
      Application.put_env(
        :whispr_calls,
        :messaging_client,
        WhisprCalls.Grpc.MessagingClientMock
      )

      on_exit(fn ->
        Application.put_env(
          :whispr_calls,
          :messaging_client,
          WhisprCalls.Grpc.MessagingClient.Stub
        )
      end)

      expect(WhisprCalls.Grpc.MessagingClientMock, :verify_membership, fn _conv, _user ->
        {:error, :not_member}
      end)

      assert {:error, :not_member} =
               Calls.initiate_call(Ecto.UUID.generate(), Ecto.UUID.generate(), %{
                 type: "audio",
                 participant_ids: []
               })

      # No call was created and no LiveKit interaction happened.
      assert Repo.all(Call) == []
    end

    test "succeeds when all invitees are members of the conversation" do
      Application.put_env(
        :whispr_calls,
        :messaging_client,
        WhisprCalls.Grpc.MessagingClientMock
      )

      on_exit(fn ->
        Application.put_env(
          :whispr_calls,
          :messaging_client,
          WhisprCalls.Grpc.MessagingClient.Stub
        )
      end)

      initiator = Ecto.UUID.generate()
      invitee_a = Ecto.UUID.generate()
      invitee_b = Ecto.UUID.generate()

      expect(WhisprCalls.Grpc.MessagingClientMock, :verify_membership, fn _conv, ^initiator ->
        {:ok, :member}
      end)

      expect(WhisprCalls.Grpc.MessagingClientMock, :list_members, fn _conv ->
        {:ok, [initiator, invitee_a, invitee_b]}
      end)

      expect(LiveKitClientMock, :create_room, fn _name, _opts -> {:ok, %{}} end)

      expect(LiveKitClientMock, :generate_access_token, fn ^initiator, _room, _opts ->
        {:ok, "lk_token"}
      end)

      assert {:ok, _call, _tokens} =
               Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
                 type: "video",
                 participant_ids: [invitee_a, invitee_b]
               })
    end

    test "returns :invitee_not_member when an invitee is NOT in the conversation" do
      Application.put_env(
        :whispr_calls,
        :messaging_client,
        WhisprCalls.Grpc.MessagingClientMock
      )

      on_exit(fn ->
        Application.put_env(
          :whispr_calls,
          :messaging_client,
          WhisprCalls.Grpc.MessagingClient.Stub
        )
      end)

      initiator = Ecto.UUID.generate()
      legit_invitee = Ecto.UUID.generate()
      stranger = Ecto.UUID.generate()

      expect(WhisprCalls.Grpc.MessagingClientMock, :verify_membership, fn _conv, ^initiator ->
        {:ok, :member}
      end)

      expect(WhisprCalls.Grpc.MessagingClientMock, :list_members, fn _conv ->
        {:ok, [initiator, legit_invitee]}
      end)

      assert {:error, :invitee_not_member} =
               Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
                 type: "audio",
                 participant_ids: [legit_invitee, stranger]
               })

      # No call was created and no LiveKit interaction happened.
      assert Repo.all(Call) == []
    end
  end

  describe "accept_call/2" do
    setup do
      {initiator, invitee, call} = seed_ringing_call()
      %{initiator: initiator, invitee: invitee, call: call}
    end

    test "promotes participant from invited to joined and call to connected",
         %{invitee: invitee, call: call} do
      expect(LiveKitClientMock, :generate_access_token, fn ^invitee, _room, _opts ->
        {:ok, "invitee_token"}
      end)

      assert {:ok, updated_call, %{token: "invitee_token", url: _url}} =
               Calls.accept_call(call.id, invitee)

      assert updated_call.status == "connected"
      assert %{connected_at: %DateTime{}} = updated_call

      participant = Repo.get_by!(CallParticipant, call_id: call.id, user_id: invitee)
      assert participant.status == "joined"
      assert %DateTime{} = participant.joined_at
    end

    test "returns :not_invited when user is not a participant", %{call: call} do
      stranger = Ecto.UUID.generate()
      assert {:error, :not_invited} = Calls.accept_call(call.id, stranger)
    end
  end

  describe "decline_call/2" do
    setup do
      {initiator, invitee, call} = seed_ringing_call()
      %{initiator: initiator, invitee: invitee, call: call}
    end

    test "marks participant as declined", %{invitee: invitee, call: call} do
      assert {:ok, _call} = Calls.decline_call(call.id, invitee)

      participant = Repo.get_by!(CallParticipant, call_id: call.id, user_id: invitee)
      assert participant.status == "declined"
    end

    test "returns :not_invited for non-participant", %{call: call} do
      assert {:error, :not_invited} = Calls.decline_call(call.id, Ecto.UUID.generate())
    end
  end

  describe "end_call/2" do
    setup do
      {initiator, invitee, call} = seed_connected_call()
      %{initiator: initiator, invitee: invitee, call: call}
    end

    test "1v1: ends the call as soon as the first peer leaves",
         %{initiator: _initiator, invitee: invitee, call: call} do
      expect(LiveKitClientMock, :delete_room, fn _room -> :ok end)

      assert {:ok, updated_call} = Calls.end_call(call.id, invitee)
      assert updated_call.status == "ended"
      assert updated_call.end_reason == "peer_left"
      assert %DateTime{} = updated_call.ended_at
      assert is_integer(updated_call.duration_seconds)
      assert updated_call.duration_seconds >= 0

      participant = Repo.get_by!(CallParticipant, call_id: call.id, user_id: invitee)
      assert participant.status == "left"
    end

    test "returns :not_invited for non-participant", %{call: call} do
      assert {:error, :not_invited} = Calls.end_call(call.id, Ecto.UUID.generate())
    end

    test "1v1: second peer leaving after the call ended is a no-op",
         %{initiator: initiator, invitee: invitee, call: call} do
      # First leave already ends the 1v1 call and deletes the room.
      expect(LiveKitClientMock, :delete_room, fn _ -> :ok end)
      assert {:ok, ended} = Calls.end_call(call.id, invitee)
      assert ended.status == "ended"

      # Second leave from the initiator must not re-delete the room or
      # re-publish an event; no additional delete_room expectation is set.
      assert {:ok, still_ended} = Calls.end_call(call.id, initiator)
      assert still_ended.status == "ended"
    end

    test "group call: stays connected until the last active participant leaves" do
      {a, b, c, call} = seed_connected_group_call()

      # First two leaves keep the call alive.
      assert {:ok, _} = Calls.end_call(call.id, a)
      assert Repo.get!(Call, call.id).status == "connected"

      assert {:ok, _} = Calls.end_call(call.id, b)
      assert Repo.get!(Call, call.id).status == "connected"

      # Last active participant ends the call.
      expect(LiveKitClientMock, :delete_room, fn _ -> :ok end)
      assert {:ok, ended} = Calls.end_call(call.id, c)
      assert ended.status == "ended"
      assert ended.end_reason == "all_left"
    end

    test "1v1: publishes whispr:calls:ended on the first peer leave",
         %{invitee: invitee, call: call} do
      WhisprCalls.Events.PublisherTestRecorder.subscribe()
      expect(LiveKitClientMock, :delete_room, fn _ -> :ok end)

      assert {:ok, _ended} = Calls.end_call(call.id, invitee)

      assert_receive {:published, "whispr:calls:participant_left", %{user_id: ^invitee}}, 500
      assert_receive {:published, "whispr:calls:ended", %{end_reason: "peer_left"}}, 500
    end

    test "idempotent : end_call sur un call deja ended ne re-finalize pas" do
      {a, b, c, call} = seed_connected_group_call()

      # Premier all_left finalize le call.
      expect(LiveKitClientMock, :delete_room, fn _ -> :ok end)
      assert {:ok, _} = Calls.end_call(call.id, a)
      assert {:ok, _} = Calls.end_call(call.id, b)
      assert {:ok, ended} = Calls.end_call(call.id, c)
      assert ended.status == "ended"

      # Un nouveau end_call (ex: webhook participant_left tardif d un peer
      # deja "left") doit etre idempotent : pas de delete_room ni de
      # republish, retour {:ok, call}. Aucune nouvelle expect sur le mock.
      assert {:ok, still_ended} = Calls.end_call(call.id, a)
      assert still_ended.status == "ended"
      assert still_ended.end_reason == "all_left"
    end

    test "groupe : leaves concurrents serialises par le lock FOR UPDATE" do
      # 3 participants, on lance 2 leaves concurrents (a et b). Avec le lock
      # FOR UPDATE le second observe l etat post-premier-leave et conclut
      # has_active_participants? == true (c est encore joined). Le call doit
      # rester connected, c reste joined, et aucun delete_room n est appele.
      {a, b, c, call} = seed_connected_group_call()

      parent = self()

      tasks =
        Enum.map([a, b], fn user_id ->
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
            Calls.end_call(call.id, user_id)
          end)
        end)

      results = Task.await_many(tasks, 5_000)
      assert Enum.all?(results, fn r -> match?({:ok, _}, r) end)

      # Le call est toujours connected, c est encore joined.
      assert Repo.get!(Call, call.id).status == "connected"
      assert Repo.get_by!(CallParticipant, call_id: call.id, user_id: c).status == "joined"

      # a et b sont maintenant en "left".
      assert Repo.get_by!(CallParticipant, call_id: call.id, user_id: a).status == "left"
      assert Repo.get_by!(CallParticipant, call_id: call.id, user_id: b).status == "left"
    end
  end

  describe "accept_call/2 on an already-ended call" do
    test "returns :call_already_ended" do
      {_initiator, invitee, call} = seed_ringing_call()

      {:ok, _} =
        call
        |> Call.changeset(%{status: "ended", ended_at: DateTime.utc_now()})
        |> Repo.update()

      assert {:error, :call_already_ended} = Calls.accept_call(call.id, invitee)
    end
  end

  describe "decline_call/2 on an already-ended call" do
    test "returns :call_already_ended" do
      {_initiator, invitee, call} = seed_ringing_call()

      {:ok, ended} =
        call
        |> Call.changeset(%{status: "ended", ended_at: DateTime.utc_now()})
        |> Repo.update()

      assert {:error, :call_already_ended} = Calls.decline_call(ended.id, invitee)
    end
  end

  describe "accept_call/2 status guards" do
    test "returns :call_not_ringing when call is already connected" do
      {_initiator, invitee, call} = seed_ringing_call()

      {:ok, _} =
        call
        |> Call.changeset(%{status: "connected", connected_at: DateTime.utc_now()})
        |> Repo.update()

      assert {:error, :call_not_ringing} = Calls.accept_call(call.id, invitee)
    end

    test "returns :participant_not_invited when participant already declined" do
      {_initiator, invitee, call} = seed_ringing_call()

      participant = Repo.get_by!(CallParticipant, call_id: call.id, user_id: invitee)

      {:ok, _} =
        participant
        |> CallParticipant.changeset(%{status: "declined"})
        |> Repo.update()

      assert {:error, :participant_not_invited} = Calls.accept_call(call.id, invitee)
    end

    test "returns :participant_not_invited when initiator (already joined) tries to accept" do
      {initiator, _invitee, call} = seed_ringing_call()

      assert {:error, :participant_not_invited} = Calls.accept_call(call.id, initiator)
    end

    test "second accept errors after a successful first accept" do
      {_initiator, invitee, call} = seed_ringing_call()

      expect(LiveKitClientMock, :generate_access_token, fn ^invitee, _room, _opts ->
        {:ok, "tok"}
      end)

      assert {:ok, _, _} = Calls.accept_call(call.id, invitee)
      assert {:error, :call_not_ringing} = Calls.accept_call(call.id, invitee)
    end
  end

  describe "decline_call/2 status guards" do
    test "returns :call_not_ringing when call is already connected" do
      {_initiator, invitee, call} = seed_ringing_call()

      {:ok, _} =
        call
        |> Call.changeset(%{status: "connected", connected_at: DateTime.utc_now()})
        |> Repo.update()

      assert {:error, :call_not_ringing} = Calls.decline_call(call.id, invitee)
    end

    test "returns :call_already_ended when call is missed" do
      {_initiator, invitee, call} = seed_ringing_call()

      {:ok, _} =
        call
        |> Call.changeset(%{status: "missed"})
        |> Repo.update()

      assert {:error, :call_already_ended} = Calls.decline_call(call.id, invitee)
    end

    test "returns :participant_not_invited when participant already declined" do
      {_initiator, invitee, call} = seed_ringing_call()

      participant = Repo.get_by!(CallParticipant, call_id: call.id, user_id: invitee)

      {:ok, _} =
        participant
        |> CallParticipant.changeset(%{status: "declined"})
        |> Repo.update()

      assert {:error, :participant_not_invited} = Calls.decline_call(call.id, invitee)
    end

    test "decline then accept errors" do
      {_initiator, invitee, call} = seed_ringing_call()

      assert {:ok, _} = Calls.decline_call(call.id, invitee)
      assert {:error, :participant_not_invited} = Calls.accept_call(call.id, invitee)
    end

    test "second decline errors after a successful first decline" do
      {_initiator, invitee, call} = seed_ringing_call()

      assert {:ok, _} = Calls.decline_call(call.id, invitee)
      assert {:error, :participant_not_invited} = Calls.decline_call(call.id, invitee)
    end
  end

  describe "list_user_calls/2" do
    test "returns calls the user participates in, newest first" do
      user = Ecto.UUID.generate()
      {_i1, _v1, call1} = seed_ringing_call_for(user)
      {_i2, _v2, call2} = seed_ringing_call_for(user)

      other_user = Ecto.UUID.generate()
      _ = seed_ringing_call_for(other_user)

      ids =
        user
        |> Calls.list_user_calls(%{})
        |> Enum.map(& &1.id)

      assert Enum.sort(ids) == Enum.sort([call1.id, call2.id])
    end

    test ":status filter only keeps calls with the matching status" do
      user = Ecto.UUID.generate()
      {_i, _v, ringing} = seed_ringing_call_for(user)

      # Promote the second call to ended.
      {_i2, _v2, other} = seed_ringing_call_for(user)

      {:ok, _} =
        other
        |> Call.changeset(%{status: "ended", ended_at: DateTime.utc_now()})
        |> Repo.update()

      assert [%Call{id: id, status: "ringing"}] =
               Calls.list_user_calls(user, %{status: "ringing"})

      assert id == ringing.id
    end

    test ":conversation_id filter only keeps calls in that conversation" do
      user = Ecto.UUID.generate()
      {_i, _v, target} = seed_ringing_call_for(user)
      {_i2, _v2, _other} = seed_ringing_call_for(user)

      assert [%Call{id: id}] =
               Calls.list_user_calls(user, %{conversation_id: target.conversation_id})

      assert id == target.id
    end
  end

  describe "get_call_if_participant/2" do
    test "returns the call if user is a participant" do
      {initiator, _invitee, call} = seed_ringing_call()
      assert {:ok, fetched} = Calls.get_call_if_participant(call.id, initiator)
      assert fetched.id == call.id
    end

    test "returns :not_found when user is not a participant" do
      {_initiator, _invitee, call} = seed_ringing_call()
      assert {:error, :not_found} = Calls.get_call_if_participant(call.id, Ecto.UUID.generate())
    end
  end

  describe "fetch_call edge cases" do
    test "accept_call with an unknown call_id returns :call_not_found" do
      assert {:error, :call_not_found} =
               Calls.accept_call(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "decline_call with an unknown call_id returns :call_not_found" do
      assert {:error, :call_not_found} =
               Calls.decline_call(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "end_call with an unknown call_id returns :call_not_found" do
      assert {:error, :call_not_found} =
               Calls.end_call(Ecto.UUID.generate(), Ecto.UUID.generate())
    end

    test "handle_participant_left with an unknown room returns :not_found" do
      assert {:error, :not_found} =
               Calls.handle_participant_left("call_unknown", Ecto.UUID.generate())
    end
  end

  describe "messaging-service list_members/1 transport failures" do
    test "returns :invitee_not_member when list_members itself errors" do
      Application.put_env(
        :whispr_calls,
        :messaging_client,
        WhisprCalls.Grpc.MessagingClientMock
      )

      on_exit(fn ->
        Application.put_env(
          :whispr_calls,
          :messaging_client,
          WhisprCalls.Grpc.MessagingClient.Stub
        )
      end)

      initiator = Ecto.UUID.generate()

      expect(WhisprCalls.Grpc.MessagingClientMock, :verify_membership, fn _, _ ->
        {:ok, :member}
      end)

      expect(WhisprCalls.Grpc.MessagingClientMock, :list_members, fn _ ->
        {:error, :timeout}
      end)

      assert {:error, :invitee_not_member} =
               Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
                 type: "audio",
                 participant_ids: [Ecto.UUID.generate()]
               })
    end
  end

  describe "handle_room_finished/1" do
    test "marks a ringing call as ended with end_reason room_finished" do
      {_initiator, _invitee, call} = seed_ringing_call()

      expect(LiveKitClientMock, :delete_room, fn _room -> :ok end)

      assert {:ok, updated} = Calls.handle_room_finished(call.livekit_room)
      assert updated.status == "ended"
      assert updated.end_reason == "room_finished"
    end

    test "is a no-op on an already ended call" do
      {_initiator, _invitee, call} = seed_ringing_call()

      {:ok, _} =
        call
        |> Call.changeset(%{status: "ended", ended_at: DateTime.utc_now(), end_reason: "test"})
        |> Repo.update()

      assert {:ok, refreshed} = Calls.handle_room_finished(call.livekit_room)
      assert refreshed.status == "ended"
      assert refreshed.end_reason == "test"
    end

    test "returns :not_found when room does not exist" do
      assert {:error, :not_found} = Calls.handle_room_finished("call_nope")
    end
  end

  describe "handle_participant_left/2" do
    test "marks the matching participant as left" do
      {initiator, _invitee, call} = seed_connected_call()
      # 1v1: first leave finalizes the call and deletes the LiveKit room.
      expect(LiveKitClientMock, :delete_room, fn _ -> :ok end)

      assert {:ok, _} = Calls.handle_participant_left(call.livekit_room, initiator)

      participant = Repo.get_by!(CallParticipant, call_id: call.id, user_id: initiator)
      assert participant.status == "left"
    end
  end

  describe "accept_call/2 race condition (WHISPR-1370)" do
    # 2 participants invites au meme call de groupe acceptent en parallele.
    # Avant le fix : 2 accept reussissaient car les 2 transactions lisaient
    # un snapshot stale "ringing" et flippaient toutes les deux le call.
    # Apres : le verrou FOR UPDATE serialise. Une seule transaction passe
    # ringing -> connected, l autre voit "connected" sous lock et echoue
    # proprement avec :call_not_ringing (comportement existant pour un
    # accept apres un autre accept reussi).
    test "2 accept concurrents sur un group call -> serialisation par FOR UPDATE" do
      {_initiator, invitee_a, invitee_b, call} = seed_ringing_group_call()

      Mox.set_mox_global()

      stub(LiveKitClientMock, :generate_access_token, fn user_id, _room, _opts ->
        {:ok, "tok_" <> user_id}
      end)

      tasks =
        for uid <- [invitee_a, invitee_b] do
          Task.async(fn -> Calls.accept_call(call.id, uid) end)
        end

      results = Task.await_many(tasks, 5_000)
      successes = Enum.count(results, &match?({:ok, _, _}, &1))
      failures = Enum.count(results, &match?({:error, :call_not_ringing}, &1))

      # Sans le verrou : les 2 reussissaient (race). Avec : 1 + 1.
      assert successes == 1
      assert failures == 1

      # Le call est passe une seule fois en "connected".
      reloaded = Repo.get!(Call, call.id)
      assert reloaded.status == "connected"
      assert %DateTime{} = reloaded.connected_at

      # L invitee qui a gagne la course est "joined", l autre reste "invited".
      joined_count =
        Repo.aggregate(
          from(p in CallParticipant,
            where:
              p.call_id == ^call.id and p.user_id in ^[invitee_a, invitee_b] and
                p.status == "joined"
          ),
          :count
        )

      assert joined_count == 1
    end

    # Si le meme participant accepte 2 fois en concurrence (rejeu reseau),
    # le verrou garantit qu un seul des 2 reussit, l autre voit le statut
    # deja "joined" et echoue avec :participant_not_invited (ou :call_not_ringing).
    test "double accept concurrent du meme participant -> un seul succes" do
      {_initiator, invitee, call} = seed_ringing_call()

      Mox.set_mox_global()

      stub(LiveKitClientMock, :generate_access_token, fn _uid, _room, _opts ->
        {:ok, "tok"}
      end)

      tasks =
        for _ <- 1..2 do
          Task.async(fn -> Calls.accept_call(call.id, invitee) end)
        end

      results = Task.await_many(tasks, 5_000)
      successes = Enum.count(results, &match?({:ok, _, _}, &1))
      failures = Enum.count(results, &match?({:error, _}, &1))

      assert successes == 1
      assert failures == 1

      [{:error, reason}] = Enum.filter(results, &match?({:error, _}, &1))
      assert reason in [:call_not_ringing, :participant_not_invited]
    end
  end

  describe "finalize_call revoke_participant" do
    test "kick chaque participant LiveKit avant delete_room (WHISPR-1363)" do
      {initiator, invitee, call} = seed_connected_call()

      # 2 participants -> on doit voir 2 revoke avant le delete_room.
      expect(LiveKitClientMock, :revoke_participant, 2, fn _room, user_id ->
        assert user_id in [initiator, invitee]
        :ok
      end)

      expect(LiveKitClientMock, :delete_room, fn _room -> :ok end)

      assert {:ok, ended} = Calls.end_call(call.id, invitee)
      assert ended.status == "ended"
    end
  end

  describe "redis active-participants cleanup" do
    test "finalize_call drops calls:{room}:participants in Redis" do
      {initiator, invitee, call} = seed_connected_call()
      key = "calls:#{call.livekit_room}:participants"

      # Pre-populate the set the way `track_active_participant/2` would.
      {:ok, _} = Redix.command(:redix, ["SADD", key, initiator, invitee])
      assert {:ok, 2} = Redix.command(:redix, ["SCARD", key])

      # 1v1 call: the first `end_call` finalizes immediately (peer_left),
      # which DELs the Redis set and calls delete_room on LiveKit.
      expect(LiveKitClientMock, :delete_room, fn _ -> :ok end)
      assert {:ok, _} = Calls.end_call(call.id, invitee)

      assert {:ok, 0} = Redix.command(:redix, ["EXISTS", key])
    end
  end

  defp seed_ringing_call_for(user_id) do
    invitee = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: user_id,
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        livekit_room: "call_" <> Ecto.UUID.generate(),
        started_at: now
      })
      |> Repo.insert()

    Repo.insert_all(CallParticipant, [
      %{
        call_id: call.id,
        user_id: user_id,
        status: "joined",
        invited_at: now,
        joined_at: now
      },
      %{
        call_id: call.id,
        user_id: invitee,
        status: "invited",
        invited_at: now
      }
    ])

    {user_id, invitee, call}
  end

  # Seeds a ringing call with 1 initiator (joined) + 1 invitee (invited)
  # without going through initiate_call/3, so we don't need to expect mock
  # calls for the seed. Returns {initiator_id, invitee_id, call}.
  defp seed_ringing_call do
    initiator = Ecto.UUID.generate()
    invitee = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: initiator,
        conversation_id: Ecto.UUID.generate(),
        type: "video",
        livekit_room: "call_" <> Ecto.UUID.generate(),
        started_at: now
      })
      |> Repo.insert()

    Repo.insert_all(CallParticipant, [
      %{
        call_id: call.id,
        user_id: initiator,
        status: "joined",
        invited_at: now,
        joined_at: now
      },
      %{
        call_id: call.id,
        user_id: invitee,
        status: "invited",
        invited_at: now
      }
    ])

    {initiator, invitee, call}
  end

  # Seeds a 3-participant ringing group call: initiator (joined) + 2 invitees (invited).
  defp seed_ringing_group_call do
    initiator = Ecto.UUID.generate()
    invitee_a = Ecto.UUID.generate()
    invitee_b = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: initiator,
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        livekit_room: "call_" <> Ecto.UUID.generate(),
        started_at: now
      })
      |> Repo.insert()

    Repo.insert_all(CallParticipant, [
      %{
        call_id: call.id,
        user_id: initiator,
        status: "joined",
        invited_at: now,
        joined_at: now
      },
      %{
        call_id: call.id,
        user_id: invitee_a,
        status: "invited",
        invited_at: now
      },
      %{
        call_id: call.id,
        user_id: invitee_b,
        status: "invited",
        invited_at: now
      }
    ])

    {initiator, invitee_a, invitee_b, call}
  end

  # Seeds a 3-participant connected call (group call), all joined.
  defp seed_connected_group_call do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()
    c = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: a,
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        livekit_room: "call_" <> Ecto.UUID.generate(),
        started_at: now,
        connected_at: now,
        status: "connected"
      })
      |> Repo.insert()

    Repo.insert_all(
      CallParticipant,
      Enum.map([a, b, c], fn uid ->
        %{
          call_id: call.id,
          user_id: uid,
          status: "joined",
          invited_at: now,
          joined_at: now
        }
      end)
    )

    {a, b, c, call}
  end

  # Seeds a connected call with both users joined.
  defp seed_connected_call do
    initiator = Ecto.UUID.generate()
    invitee = Ecto.UUID.generate()
    now = DateTime.utc_now()

    {:ok, call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: initiator,
        conversation_id: Ecto.UUID.generate(),
        type: "video",
        livekit_room: "call_" <> Ecto.UUID.generate(),
        started_at: now,
        connected_at: now,
        status: "connected"
      })
      |> Repo.insert()

    Repo.insert_all(CallParticipant, [
      %{
        call_id: call.id,
        user_id: initiator,
        status: "joined",
        invited_at: now,
        joined_at: now
      },
      %{
        call_id: call.id,
        user_id: invitee,
        status: "joined",
        invited_at: now,
        joined_at: now
      }
    ])

    {initiator, invitee, call}
  end
end

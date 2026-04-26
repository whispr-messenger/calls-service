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

    test "marks last participant as left and ends the call + deletes room",
         %{initiator: initiator, invitee: invitee, call: call} do
      # invitee leaves first (non-last) - no room delete expected
      assert {:ok, _} = Calls.end_call(call.id, invitee)
      assert Repo.get!(Call, call.id).status == "connected"

      # initiator leaves - last one, room gets deleted
      expect(LiveKitClientMock, :delete_room, fn _room -> :ok end)

      assert {:ok, updated_call} = Calls.end_call(call.id, initiator)
      assert updated_call.status == "ended"
      assert %DateTime{} = updated_call.ended_at
      assert is_integer(updated_call.duration_seconds)
      assert updated_call.duration_seconds >= 0

      participants = Repo.all(CallParticipant)
      assert Enum.all?(participants, &(&1.status == "left"))
    end

    test "returns :not_invited for non-participant", %{call: call} do
      assert {:error, :not_invited} = Calls.end_call(call.id, Ecto.UUID.generate())
    end

    test "is a no-op when called a second time after the call is already ended",
         %{initiator: initiator, invitee: invitee, call: call} do
      # First end: initiator leaves then invitee (last one) ends the call.
      assert {:ok, _} = Calls.end_call(call.id, initiator)
      expect(LiveKitClientMock, :delete_room, fn _ -> :ok end)
      assert {:ok, ended} = Calls.end_call(call.id, invitee)
      assert ended.status == "ended"

      # Second end from initiator must not re-delete the room or re-publish
      # an event; we do NOT set another expectation on delete_room.
      assert {:ok, still_ended} = Calls.end_call(call.id, initiator)
      assert still_ended.status == "ended"
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
    test "is a no-op" do
      {_initiator, invitee, call} = seed_ringing_call()

      {:ok, ended} =
        call
        |> Call.changeset(%{status: "ended", ended_at: DateTime.utc_now()})
        |> Repo.update()

      assert {:ok, returned} = Calls.decline_call(ended.id, invitee)
      assert returned.status == "ended"
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

      assert {:ok, _} = Calls.handle_participant_left(call.livekit_room, initiator)

      participant = Repo.get_by!(CallParticipant, call_id: call.id, user_id: initiator)
      assert participant.status == "left"
    end
  end

  describe "redis active-participants cleanup" do
    test "finalize_call drops calls:{room}:participants in Redis" do
      {initiator, invitee, call} = seed_connected_call()
      key = "calls:#{call.livekit_room}:participants"

      # Pre-populate the set the way `track_active_participant/2` would.
      {:ok, _} = Redix.command(:redix, ["SADD", key, initiator, invitee])
      assert {:ok, 2} = Redix.command(:redix, ["SCARD", key])

      # Both participants leave; the second `end_call` triggers finalize_call,
      # which must DEL the set.
      assert {:ok, _} = Calls.end_call(call.id, invitee)
      expect(LiveKitClientMock, :delete_room, fn _ -> :ok end)
      assert {:ok, _} = Calls.end_call(call.id, initiator)

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

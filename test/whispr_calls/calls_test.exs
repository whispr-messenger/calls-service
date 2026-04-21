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
end

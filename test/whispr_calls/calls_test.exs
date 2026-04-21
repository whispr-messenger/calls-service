defmodule WhisprCalls.CallsTest do
  use WhisprCalls.DataCase, async: false
  import Mox

  alias WhisprCalls.Calls
  alias WhisprCalls.Calls.{CallParticipant, LiveKitClientMock}
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
end

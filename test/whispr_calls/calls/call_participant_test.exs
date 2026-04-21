defmodule WhisprCalls.Calls.CallParticipantTest do
  use WhisprCalls.DataCase, async: true
  alias WhisprCalls.Calls.CallParticipant

  describe "changeset/2" do
    test "valid changeset" do
      call_id = Ecto.UUID.generate()
      user_id = Ecto.UUID.generate()

      cs =
        CallParticipant.changeset(%CallParticipant{}, %{
          call_id: call_id,
          user_id: user_id,
          status: "invited"
        })

      assert cs.valid?
    end

    test "rejects invalid status" do
      cs =
        CallParticipant.changeset(%CallParticipant{}, %{
          call_id: Ecto.UUID.generate(),
          user_id: Ecto.UUID.generate(),
          status: "whatever"
        })

      refute cs.valid?
    end
  end
end

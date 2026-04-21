defmodule WhisprCalls.Calls.CallTest do
  use WhisprCalls.DataCase, async: true
  alias WhisprCalls.Calls.Call

  describe "changeset/2" do
    @valid_attrs %{
      initiator_id: Ecto.UUID.generate(),
      conversation_id: Ecto.UUID.generate(),
      type: "video",
      livekit_room: "call_abc"
    }

    test "valid changeset" do
      changeset = Call.changeset(%Call{}, @valid_attrs)
      assert changeset.valid?
    end

    test "rejects invalid type" do
      changeset = Call.changeset(%Call{}, %{@valid_attrs | type: "hologram"})
      refute changeset.valid?
      assert %{type: ["is invalid"]} = errors_on(changeset)
    end

    test "requires all required fields" do
      changeset = Call.changeset(%Call{}, %{})
      refute changeset.valid?

      for field <- [:initiator_id, :conversation_id, :type, :livekit_room] do
        assert field in Keyword.keys(changeset.errors)
      end
    end
  end
end

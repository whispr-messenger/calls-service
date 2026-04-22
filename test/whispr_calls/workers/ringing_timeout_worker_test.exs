defmodule WhisprCalls.Workers.RingingTimeoutWorkerTest do
  use WhisprCalls.DataCase, async: false
  import Mox
  alias WhisprCalls.Calls.{Call, LiveKitClientMock}
  alias WhisprCalls.Repo
  alias WhisprCalls.Workers.RingingTimeoutWorker

  setup :verify_on_exit!

  test "expire_stale_ringing/0 marks ringing calls older than 30s as missed" do
    stale_started = DateTime.add(DateTime.utc_now(), -60, :second)
    fresh_started = DateTime.add(DateTime.utc_now(), -10, :second)

    {:ok, stale_call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: Ecto.UUID.generate(),
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        livekit_room: "call_stale_" <> Ecto.UUID.generate(),
        started_at: stale_started
      })
      |> Repo.insert()

    {:ok, fresh_call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: Ecto.UUID.generate(),
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        livekit_room: "call_fresh_" <> Ecto.UUID.generate(),
        started_at: fresh_started
      })
      |> Repo.insert()

    RingingTimeoutWorker.expire_stale_ringing()

    assert Repo.get!(Call, stale_call.id).status == "missed"
    assert Repo.get!(Call, stale_call.id).end_reason == "timeout"
    assert Repo.get!(Call, fresh_call.id).status == "ringing"

    # prevent unused alias warning
    _ = LiveKitClientMock
  end
end

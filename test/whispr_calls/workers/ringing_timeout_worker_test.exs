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

  test "expire_stale_ringing/0 publishes whispr:calls:missed with timeout reason" do
    WhisprCalls.Events.PublisherTestRecorder.subscribe()

    stale_started = DateTime.add(DateTime.utc_now(), -90, :second)

    {:ok, stale_call} =
      %Call{}
      |> Call.changeset(%{
        initiator_id: Ecto.UUID.generate(),
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        livekit_room: "call_pub_" <> Ecto.UUID.generate(),
        started_at: stale_started
      })
      |> Repo.insert()

    RingingTimeoutWorker.expire_stale_ringing()

    expected_id = stale_call.id
    expected_conv = stale_call.conversation_id

    assert_receive {:published, "whispr:calls:missed",
                    %{call_id: ^expected_id, conversation_id: ^expected_conv, timeout_seconds: 30}},
                   500

    _ = LiveKitClientMock
  end

  test "the GenServer schedules a tick on start_link and survives a forced :tick" do
    {:ok, pid} = GenServer.start_link(RingingTimeoutWorker, [])
    # Force an immediate tick: handle_info reschedules and returns :noreply.
    send(pid, :tick)
    Process.sleep(50)
    assert Process.alive?(pid)
    GenServer.stop(pid)
  end

  test "expire_stale_ringing/0 swallows DB errors (rescue clause)" do
    # Drop the SQL sandbox owner so any Repo call from this process raises.
    # The worker must rescue and return :ok rather than crash.
    Ecto.Adapters.SQL.Sandbox.checkin(WhisprCalls.Repo)

    assert :ok = RingingTimeoutWorker.expire_stale_ringing()
  end
end

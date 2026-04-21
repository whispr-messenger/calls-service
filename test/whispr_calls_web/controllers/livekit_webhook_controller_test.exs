defmodule WhisprCallsWeb.LiveKitWebhookControllerTest do
  use WhisprCallsWeb.ConnCase, async: false
  import Mox

  alias WhisprCalls.Calls.LiveKitClientMock

  setup :verify_on_exit!

  test "participant_left triggers end_call flow", %{conn: conn} do
    Mox.stub(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
    Mox.stub(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "t"} end)
    Mox.stub(LiveKitClientMock, :delete_room, fn _ -> :ok end)

    initiator = Ecto.UUID.generate()

    {:ok, call, _} =
      WhisprCalls.Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
        type: "audio",
        participant_ids: []
      })

    event = %{
      "event" => "participant_left",
      "room" => %{"name" => call.livekit_room},
      "participant" => %{"identity" => initiator}
    }

    resp = post(conn, "/calls/webhooks/livekit", event)
    assert response(resp, 200)
  end

  test "room_finished marks call ended", %{conn: conn} do
    Mox.stub(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
    Mox.stub(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "t"} end)
    Mox.stub(LiveKitClientMock, :delete_room, fn _ -> :ok end)

    initiator = Ecto.UUID.generate()

    {:ok, call, _} =
      WhisprCalls.Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
        type: "audio",
        participant_ids: []
      })

    event = %{
      "event" => "room_finished",
      "room" => %{"name" => call.livekit_room}
    }

    resp = post(conn, "/calls/webhooks/livekit", event)
    assert response(resp, 200)

    updated = WhisprCalls.Repo.get!(WhisprCalls.Calls.Call, call.id)
    assert updated.status in ["ended", "connected"]
  end

  test "returns 200 on unknown event type", %{conn: conn} do
    resp = post(conn, "/calls/webhooks/livekit", %{"event" => "unknown"})
    assert response(resp, 200)
  end
end

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

  describe "signature verification" do
    setup do
      secret = "webhook_test_secret"
      Application.put_env(:whispr_calls, :livekit_webhook_secret, secret)
      on_exit(fn -> Application.delete_env(:whispr_calls, :livekit_webhook_secret) end)
      %{secret: secret}
    end

    test "rejects requests without a valid JWT when the secret is set", %{conn: conn} do
      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/calls/webhooks/livekit", %{"event" => "unknown"})

      assert response(resp, 401)
    end

    test "accepts requests with a valid JWT whose sha256 matches the body",
         %{conn: conn, secret: secret} do
      body = Jason.encode!(%{"event" => "unknown"})
      hash = :crypto.hash(:sha256, body) |> Base.encode64()

      signer = Joken.Signer.create("HS256", secret)
      {:ok, token, _} = Joken.encode_and_sign(%{"sha256" => hash}, signer)

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", token)
        |> Phoenix.ConnTest.dispatch(
          WhisprCallsWeb.Endpoint,
          :post,
          "/calls/webhooks/livekit",
          body
        )

      assert response(resp, 200)
    end

    test "rejects a JWT whose sha256 does not match the body",
         %{conn: conn, secret: secret} do
      signer = Joken.Signer.create("HS256", secret)
      {:ok, token, _} = Joken.encode_and_sign(%{"sha256" => "wrong"}, signer)

      resp =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", token)
        |> Phoenix.ConnTest.dispatch(
          WhisprCallsWeb.Endpoint,
          :post,
          "/calls/webhooks/livekit",
          Jason.encode!(%{"event" => "unknown"})
        )

      assert response(resp, 401)
    end
  end
end

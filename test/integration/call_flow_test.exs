defmodule WhisprCalls.Integration.CallFlowTest do
  use WhisprCallsWeb.ConnCase, async: false
  import Mox
  alias WhisprCalls.Calls.LiveKitClientMock

  setup :verify_on_exit!

  test "initiate -> accept -> end full flow via REST" do
    Mox.stub(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
    Mox.stub(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "tok"} end)
    Mox.stub(LiveKitClientMock, :delete_room, fn _ -> :ok end)

    initiator = Ecto.UUID.generate()
    callee = Ecto.UUID.generate()
    conv = Ecto.UUID.generate()

    # Initiate
    conn_i = build_auth_conn(initiator)

    create_resp =
      post(conn_i, "/calls/api/v1/calls", %{
        conversation_id: conv,
        type: "video",
        participant_ids: [callee]
      })

    assert %{"call_id" => call_id} = json_response(create_resp, 201)

    # Accept
    conn_c = build_auth_conn(callee)
    accept_resp = post(conn_c, "/calls/api/v1/calls/#{call_id}/accept")
    assert %{"livekit_token" => "tok"} = json_response(accept_resp, 200)

    # End
    end_resp = delete(conn_c, "/calls/api/v1/calls/#{call_id}")
    assert response(end_resp, 204)

    call = WhisprCalls.Repo.get(WhisprCalls.Calls.Call, call_id)
    assert call.status in ["ended", "connected"]
  end

  test "initiate rejected with 403 when user is not a conversation member" do
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

    initiator = Ecto.UUID.generate()
    conn = build_auth_conn(initiator)

    resp =
      post(conn, "/calls/api/v1/calls", %{
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        participant_ids: []
      })

    # FallbackController maps :not_member to 403 Forbidden
    assert json_response(resp, 403)
  end

  test "ending a call twice returns 404 on the second attempt" do
    Mox.stub(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
    Mox.stub(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "tok"} end)
    Mox.stub(LiveKitClientMock, :delete_room, fn _ -> :ok end)

    initiator = Ecto.UUID.generate()
    callee = Ecto.UUID.generate()

    # Initiate
    conn_i = build_auth_conn(initiator)

    %{"call_id" => call_id} =
      conn_i
      |> post("/calls/api/v1/calls", %{
        conversation_id: Ecto.UUID.generate(),
        type: "audio",
        participant_ids: [callee]
      })
      |> json_response(201)

    # Accept then end fully (only participant).
    conn_c = build_auth_conn(callee)
    _ = post(conn_c, "/calls/api/v1/calls/#{call_id}/accept")
    _ = delete(conn_c, "/calls/api/v1/calls/#{call_id}")
    _ = delete(conn_i, "/calls/api/v1/calls/#{call_id}")

    # Call should be fully ended at this point.
    call = WhisprCalls.Repo.get(WhisprCalls.Calls.Call, call_id)
    assert call.status == "ended"

    # A subsequent GET by a non-participant must resolve to 404.
    conn_stranger = build_auth_conn(Ecto.UUID.generate())
    resp = get(conn_stranger, "/calls/api/v1/calls/#{call_id}")
    assert json_response(resp, 404)
  end

  defp build_auth_conn(user_id) do
    {alg, secret} = Application.fetch_env!(:whispr_calls, :jwt_signer)
    signer = Joken.Signer.create(alg, secret)
    {:ok, token, _} = Joken.encode_and_sign(%{"sub" => user_id}, signer)
    build_conn() |> put_req_header("authorization", "Bearer " <> token)
  end
end

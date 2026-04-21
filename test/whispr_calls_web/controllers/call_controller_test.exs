defmodule WhisprCallsWeb.CallControllerTest do
  use WhisprCallsWeb.ConnCase, async: false
  import Mox
  alias WhisprCalls.Calls.LiveKitClientMock

  setup :verify_on_exit!

  setup %{conn: conn} do
    user_id = Ecto.UUID.generate()
    token = build_valid_test_jwt(%{"sub" => user_id})

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("accept", "application/json")

    %{conn: conn, user_id: user_id}
  end

  describe "POST /calls" do
    test "201 returns call + livekit_token", %{conn: conn, user_id: user_id} do
      expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
      expect(LiveKitClientMock, :generate_access_token, fn ^user_id, _, _ -> {:ok, "tok"} end)

      conn =
        post(conn, "/calls/api/v1/calls", %{
          conversation_id: Ecto.UUID.generate(),
          type: "audio",
          participant_ids: []
        })

      assert %{
               "call_id" => _,
               "livekit_token" => "tok",
               "livekit_url" => _,
               "status" => "ringing"
             } = json_response(conn, 201)
    end

    test "422 on invalid conversation_id", %{conn: conn} do
      conn = post(conn, "/calls/api/v1/calls", %{})
      assert json_response(conn, 422)
    end
  end

  describe "POST /calls/:id/accept" do
    test "200 returns livekit token for callee", %{conn: conn, user_id: callee} do
      initiator = Ecto.UUID.generate()
      expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
      expect(LiveKitClientMock, :generate_access_token, 2, fn _, _, _ -> {:ok, "tok"} end)

      {:ok, call, _} =
        WhisprCalls.Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
          type: "video",
          participant_ids: [callee]
        })

      accept_resp = post(conn, "/calls/api/v1/calls/#{call.id}/accept")
      assert %{"livekit_token" => "tok", "livekit_url" => _} = json_response(accept_resp, 200)
    end

    test "403 if user not invited", %{conn: conn} do
      initiator = Ecto.UUID.generate()
      expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
      expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "tok"} end)

      {:ok, call, _} =
        WhisprCalls.Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
          type: "audio",
          participant_ids: [Ecto.UUID.generate()]
        })

      accept_resp = post(conn, "/calls/api/v1/calls/#{call.id}/accept")
      assert json_response(accept_resp, 403)
    end
  end

  describe "DELETE /calls/:id" do
    test "204 when participant leaves", %{conn: conn, user_id: user_id} do
      expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
      expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "tok"} end)
      expect(LiveKitClientMock, :delete_room, fn _ -> :ok end)

      {:ok, call, _} =
        WhisprCalls.Calls.initiate_call(user_id, Ecto.UUID.generate(), %{
          type: "audio",
          participant_ids: []
        })

      resp = delete(conn, "/calls/api/v1/calls/#{call.id}")
      assert response(resp, 204)
    end
  end

  describe "GET /calls" do
    test "returns list of user calls", %{conn: conn, user_id: user_id} do
      expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
      expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "tok"} end)

      {:ok, _call, _} =
        WhisprCalls.Calls.initiate_call(user_id, Ecto.UUID.generate(), %{
          type: "audio",
          participant_ids: []
        })

      resp = get(conn, "/calls/api/v1/calls")
      assert %{"data" => [_call]} = json_response(resp, 200)
    end
  end

  defp build_valid_test_jwt(claims) do
    {alg, secret} = Application.fetch_env!(:whispr_calls, :jwt_signer)
    signer = Joken.Signer.create(alg, secret)
    {:ok, t, _} = Joken.encode_and_sign(claims, signer)
    t
  end
end

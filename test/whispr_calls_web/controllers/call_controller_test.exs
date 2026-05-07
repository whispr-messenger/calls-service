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

  describe "POST /calls/:id/decline" do
    test "204 when invitee declines a ringing call", %{conn: conn, user_id: callee} do
      initiator = Ecto.UUID.generate()
      expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
      expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "tok"} end)

      {:ok, call, _} =
        WhisprCalls.Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
          type: "audio",
          participant_ids: [callee]
        })

      resp = post(conn, "/calls/api/v1/calls/#{call.id}/decline")
      assert response(resp, 204)
    end
  end

  describe "GET /calls/:id" do
    test "200 returns the serialized call when user is a participant",
         %{conn: conn, user_id: user_id} do
      expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
      expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "tok"} end)

      {:ok, call, _} =
        WhisprCalls.Calls.initiate_call(user_id, Ecto.UUID.generate(), %{
          type: "audio",
          participant_ids: []
        })

      resp = get(conn, "/calls/api/v1/calls/#{call.id}")
      assert %{"id" => id} = json_response(resp, 200)
      assert id == call.id
    end

    test "404 when user is not a participant", %{conn: conn} do
      stranger = Ecto.UUID.generate()
      expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
      expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "tok"} end)

      {:ok, call, _} =
        WhisprCalls.Calls.initiate_call(stranger, Ecto.UUID.generate(), %{
          type: "audio",
          participant_ids: []
        })

      resp = get(conn, "/calls/api/v1/calls/#{call.id}")
      assert json_response(resp, 404)
    end
  end

  describe "POST /calls invalid input" do
    test "422 when conversation_id is not a UUID", %{conn: conn} do
      resp = post(conn, "/calls/api/v1/calls", %{conversation_id: "not-a-uuid"})
      assert json_response(resp, 422)
    end

    test "422 when conversation_id is a non-string scalar", %{conn: conn} do
      resp = post(conn, "/calls/api/v1/calls", %{conversation_id: 42})
      assert json_response(resp, 422)
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

    test "non-integer ?limit falls back to default and does not crash",
         %{conn: conn, user_id: user_id} do
      expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
      expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "tok"} end)

      {:ok, _call, _} =
        WhisprCalls.Calls.initiate_call(user_id, Ecto.UUID.generate(), %{
          type: "audio",
          participant_ids: []
        })

      resp = get(conn, "/calls/api/v1/calls?limit=abc")
      assert %{"data" => [_call]} = json_response(resp, 200)
    end

    test "huge ?limit is clamped to 100", %{conn: conn, user_id: user_id} do
      seed_calls_for(user_id, 105)

      resp = get(conn, "/calls/api/v1/calls?limit=99999")
      %{"data" => calls} = json_response(resp, 200)
      assert length(calls) == 100
    end

    test "?status filter is applied at the SQL layer", %{conn: conn, user_id: user_id} do
      _calls = seed_calls_for(user_id, 2)

      resp = get(conn, "/calls/api/v1/calls?status=ringing")
      assert %{"data" => calls} = json_response(resp, 200)
      assert Enum.all?(calls, &(&1["status"] == "ringing"))
    end

    test "?conversation_id filter is applied at the SQL layer", %{conn: conn, user_id: user_id} do
      [_c2, _c1] = seed_calls_for(user_id, 2)
      conv = Ecto.UUID.generate()

      resp = get(conn, "/calls/api/v1/calls?conversation_id=#{conv}")
      assert %{"data" => []} = json_response(resp, 200)
    end

    test "?limit accepts integer params as well as strings", %{conn: conn, user_id: user_id} do
      seed_calls_for(user_id, 3)

      # Passing a literal integer hits the parse_int(integer, _) clause.
      resp =
        get(
          conn,
          "/calls/api/v1/calls",
          %{"limit" => 5}
        )

      assert %{"data" => calls} = json_response(resp, 200)
      assert length(calls) == 3
    end

    test "negative ?limit clamps to 1", %{conn: conn, user_id: user_id} do
      seed_calls_for(user_id, 3)
      resp = get(conn, "/calls/api/v1/calls?limit=-5")
      assert %{"data" => calls} = json_response(resp, 200)
      assert length(calls) == 1
    end

    test "?offset skips the first N results", %{conn: conn, user_id: user_id} do
      # 5 calls, ordered by started_at desc by the context
      [_c5, _c4, c3, c2, c1] = seed_calls_for(user_id, 5)

      # No offset: full window
      resp_all = get(conn, "/calls/api/v1/calls?limit=10")
      %{"data" => all} = json_response(resp_all, 200)
      assert length(all) == 5

      # offset=2 skips the 2 most recent, returns the older 3
      resp_off = get(conn, "/calls/api/v1/calls?limit=10&offset=2")
      %{"data" => paged} = json_response(resp_off, 200)
      paged_ids = Enum.map(paged, & &1["id"])
      assert paged_ids == [c3.id, c2.id, c1.id]
    end
  end

  defp build_valid_test_jwt(claims) do
    {alg, secret} = Application.fetch_env!(:whispr_calls, :jwt_signer)
    signer = Joken.Signer.create(alg, secret)
    {:ok, t, _} = Joken.encode_and_sign(claims, signer)
    t
  end

  # Inserts `count` calls owned by `user_id` directly into the DB so we don't
  # have to mock LiveKit for each one. Returns the calls newest-first (same
  # order the list endpoint returns).
  defp seed_calls_for(user_id, count) do
    base = DateTime.utc_now() |> DateTime.add(-count, :second)
    alias WhisprCalls.Calls.{Call, CallParticipant}
    alias WhisprCalls.Repo

    for i <- 1..count do
      started_at = DateTime.add(base, i, :second)

      {:ok, call} =
        %Call{}
        |> Call.changeset(%{
          initiator_id: user_id,
          conversation_id: Ecto.UUID.generate(),
          type: "audio",
          livekit_room: "call_" <> Ecto.UUID.generate(),
          started_at: started_at
        })
        |> Repo.insert()

      Repo.insert_all(CallParticipant, [
        %{
          call_id: call.id,
          user_id: user_id,
          status: "joined",
          invited_at: started_at,
          joined_at: started_at
        }
      ])

      call
    end
    |> Enum.reverse()
  end
end

defmodule WhisprCallsWeb.Plugs.RateLimitCallCreationTest do
  use WhisprCallsWeb.ConnCase, async: false

  alias WhisprCallsWeb.Plugs.RateLimitCallCreation

  # Pas de cleanup ETS automatique : chaque test genere son propre user_id
  # via Ecto.UUID.generate ou System.unique_integer pour eviter la pollution
  # entre tests. Le test "reset apres fenetre" appelle Hammer.delete_buckets
  # explicitement quand il en a besoin.

  describe "POST /calls rate limit (5/min/user)" do
    test "5 requetes successives passent en 201", %{conn: conn} do
      user_id = Ecto.UUID.generate()
      stub_livekit()

      for _i <- 1..5 do
        resp = post_create(conn, user_id)
        assert resp.status == 201
      end
    end

    test "la 6e requete est bloquee en 429 + json error", %{conn: conn} do
      user_id = Ecto.UUID.generate()
      stub_livekit()

      for _i <- 1..5 do
        assert post_create(conn, user_id).status == 201
      end

      sixth = post_create(conn, user_id)
      assert sixth.status == 429
      assert %{"error" => "rate_limit_exceeded"} = Jason.decode!(sixth.resp_body)
    end

    test "deux users differents ont des compteurs independants", %{conn: conn} do
      user_a = Ecto.UUID.generate()
      user_b = Ecto.UUID.generate()
      stub_livekit()

      for _i <- 1..5, do: assert(post_create(conn, user_a).status == 201)
      assert post_create(conn, user_a).status == 429

      # user_b a son propre bucket : 5 requetes OK.
      for _i <- 1..5, do: assert(post_create(conn, user_b).status == 201)
      assert post_create(conn, user_b).status == 429
    end
  end

  describe "plug appele en isolation (Hammer reset)" do
    test "renvoie 429 a la 6e meme sans router (unit test du plug)" do
      user_id = "user-unit-#{System.unique_integer([:positive])}"

      for _i <- 1..5 do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.assign(:current_user_id, user_id)
          |> RateLimitCallCreation.call(RateLimitCallCreation.init([]))

        refute conn.halted
      end

      blocked =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:current_user_id, user_id)
        |> RateLimitCallCreation.call(RateLimitCallCreation.init([]))

      assert blocked.halted
      assert blocked.status == 429
    end

    test "fail-closed en 401 si current_user_id absent" do
      conn =
        Phoenix.ConnTest.build_conn()
        |> RateLimitCallCreation.call(RateLimitCallCreation.init([]))

      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "reset apres la fenetre (deny + reset par delete bucket)" do
    test "vider les buckets simule la fin de fenetre et debloque l user" do
      user_id = "user-reset-#{System.unique_integer([:positive])}"

      for _i <- 1..5 do
        conn =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.assign(:current_user_id, user_id)
          |> RateLimitCallCreation.call(RateLimitCallCreation.init([]))

        refute conn.halted
      end

      blocked =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:current_user_id, user_id)
        |> RateLimitCallCreation.call(RateLimitCallCreation.init([]))

      assert blocked.status == 429

      # Simule l expiration de la fenetre 60s en clearant le bucket Hammer.
      # Hammer.delete_buckets/1 reset le compteur pour la cle.
      {:ok, _} = Hammer.delete_buckets("call_create:#{user_id}")

      reopened =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.assign(:current_user_id, user_id)
        |> RateLimitCallCreation.call(RateLimitCallCreation.init([]))

      refute reopened.halted
    end
  end

  defp stub_livekit do
    # Le pipeline rate-limit est apres :api, mais l action create du
    # controller appelle quand meme le LiveKit client. On stub default-allow.
    Mox.stub(WhisprCalls.Calls.LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)

    Mox.stub(WhisprCalls.Calls.LiveKitClientMock, :generate_access_token, fn _, _, _ ->
      {:ok, "tok"}
    end)
  end

  defp post_create(conn, user_id) do
    {alg, secret} = Application.fetch_env!(:whispr_calls, :jwt_signer)
    signer = Joken.Signer.create(alg, secret)
    {:ok, token, _} = Joken.encode_and_sign(%{"sub" => user_id}, signer)

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)
    |> Plug.Conn.put_req_header("accept", "application/json")
    |> Phoenix.ConnTest.post("/calls/api/v1/calls", %{
      conversation_id: Ecto.UUID.generate(),
      type: "audio",
      participant_ids: []
    })
  end
end

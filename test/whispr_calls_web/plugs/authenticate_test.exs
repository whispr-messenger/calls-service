defmodule WhisprCallsWeb.Plugs.AuthenticateTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias WhisprCallsWeb.Plugs.Authenticate

  @user_id "00000000-0000-0000-0000-000000000123"

  defp signer, do: Joken.Signer.create("HS256", "test_secret")

  defp sign(claims) do
    {:ok, token, _} = Joken.encode_and_sign(claims, signer())
    token
  end

  describe "call/2" do
    test "assigns current_user_id when the Authorization header contains a valid bearer token" do
      token = sign(%{"sub" => @user_id})

      conn =
        :get
        |> conn("/")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Authenticate.call([])

      refute conn.halted
      assert conn.assigns[:current_user_id] == @user_id
    end

    test "returns 401 and halts when the Authorization header is missing" do
      conn =
        :get
        |> conn("/")
        |> Authenticate.call([])

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "unauthorized"
    end

    test "returns 401 and halts when the token signature is invalid" do
      # Sign with the wrong secret so verification fails.
      wrong_signer = Joken.Signer.create("HS256", "not_the_real_secret")
      {:ok, bad_token, _} = Joken.encode_and_sign(%{"sub" => @user_id}, wrong_signer)

      conn =
        :get
        |> conn("/")
        |> put_req_header("authorization", "Bearer " <> bad_token)
        |> Authenticate.call([])

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "unauthorized"
    end
  end

  # ---------------------------------------------------------------------------
  # JWKS strategy dispatch (production path — WHISPR-1151).
  #
  # In prod `:jwt_signer` is set to an atom (module implementing the
  # `JokenJwks.SignerMatchStrategy` behaviour). Before WHISPR-1151 the plug
  # called `Joken.verify_and_validate(%{}, token, nil, %{}, [Strategy])` and
  # crashed with `UndefinedFunctionError: Strategy.before_verify/2` — every
  # authenticated request came back 500. The fix wraps the strategy in a
  # `{JokenJwks, strategy: Strategy}` hook tuple so JokenJwks's own
  # `before_verify/2` runs, resolves the signer by kid and feeds it back to
  # Joken.
  # ---------------------------------------------------------------------------
  describe "call/2 with a JWKS strategy configured as :jwt_signer" do
    setup do
      previous = Application.get_env(:whispr_calls, :jwt_signer)

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:whispr_calls, :jwt_signer)
          value -> Application.put_env(:whispr_calls, :jwt_signer, value)
        end
      end)

      :ok
    end

    test "accepts a bearer token when the strategy resolves a matching signer" do
      Application.put_env(:whispr_calls, :jwt_signer, WhisprCalls.FakeJwksStrategy)

      signer = WhisprCalls.FakeJwksStrategy.signer()
      {:ok, token, _} = Joken.encode_and_sign(%{"sub" => @user_id}, signer)

      conn =
        :get
        |> conn("/")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Authenticate.call([])

      refute conn.halted
      assert conn.assigns[:current_user_id] == @user_id
    end

    test "returns 401 (not 500) when the strategy cannot resolve a signer" do
      Application.put_env(:whispr_calls, :jwt_signer, WhisprCalls.NoSignerJwksStrategy)

      {:ok, token, _} =
        Joken.encode_and_sign(
          %{"sub" => @user_id},
          Joken.Signer.create("HS256", "irrelevant", %{"kid" => "unknown-kid"})
        )

      conn =
        :get
        |> conn("/")
        |> put_req_header("authorization", "Bearer " <> token)
        |> Authenticate.call([])

      assert conn.halted
      assert conn.status == 401
      assert conn.resp_body =~ "unauthorized"
    end
  end
end

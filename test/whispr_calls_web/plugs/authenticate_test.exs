defmodule WhisprCallsWeb.Plugs.AuthenticateTest do
  use ExUnit.Case, async: true

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
end

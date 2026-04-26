defmodule WhisprCalls.Grpc.MessagingClientTest do
  use ExUnit.Case, async: false

  alias WhisprCalls.Grpc.MessagingClient
  alias WhisprCalls.Grpc.MessagingClient.HTTP
  alias WhisprCalls.Grpc.MessagingClient.Stub

  describe "dispatch via :messaging_client app env" do
    test "delegates to the configured implementation, not the Stub" do
      original = Application.get_env(:whispr_calls, :messaging_client)

      Application.put_env(
        :whispr_calls,
        :messaging_client,
        WhisprCalls.Grpc.MessagingClientMock
      )

      on_exit(fn ->
        Application.put_env(:whispr_calls, :messaging_client, original)
      end)

      Mox.expect(WhisprCalls.Grpc.MessagingClientMock, :verify_membership, fn conv, user ->
        send(self(), {:mock_called, conv, user})
        {:error, :not_member}
      end)

      assert {:error, :not_member} = MessagingClient.verify_membership("conv-1", "user-1")
      assert_received {:mock_called, "conv-1", "user-1"}
    end

    test "Stub returns {:ok, :member} unconditionally (kept for dev only)" do
      assert {:ok, :member} = Stub.verify_membership("any-conv", "any-user")
    end
  end

  describe "HTTP.verify_membership/2" do
    setup do
      original_endpoint = Application.get_env(:whispr_calls, :messaging_http_endpoint)
      original_token = Application.get_env(:whispr_calls, :messaging_service_token)
      original_req_opts = Application.get_env(:whispr_calls, :messaging_http_req_options)

      Application.put_env(:whispr_calls, :messaging_http_endpoint, "http://messaging.test")
      Application.put_env(:whispr_calls, :messaging_service_token, "test-token")

      on_exit(fn ->
        restore(:messaging_http_endpoint, original_endpoint)
        restore(:messaging_service_token, original_token)
        restore(:messaging_http_req_options, original_req_opts)
      end)

      :ok
    end

    test "returns {:ok, :member} when user is in the members list" do
      stub_req(fn conn ->
        assert conn.request_path == "/messaging/api/v1/conversations/conv-1/members"
        assert {"authorization", "Bearer test-token"} in conn.req_headers

        Req.Test.json(conn, %{
          "members" => [
            %{"user_id" => "user-other"},
            %{"user_id" => "user-1"}
          ]
        })
      end)

      assert {:ok, :member} = HTTP.verify_membership("conv-1", "user-1")
    end

    test "returns {:error, :not_member} when user is not in the members list" do
      stub_req(fn conn ->
        Req.Test.json(conn, %{"members" => [%{"user_id" => "someone-else"}]})
      end)

      assert {:error, :not_member} = HTTP.verify_membership("conv-1", "user-1")
    end

    test "returns {:error, :not_member} on HTTP 403" do
      stub_req(fn conn ->
        Plug.Conn.send_resp(conn, 403, "")
      end)

      assert {:error, :not_member} = HTTP.verify_membership("conv-1", "user-1")
    end

    test "returns {:error, :not_member} on HTTP 404" do
      stub_req(fn conn ->
        Plug.Conn.send_resp(conn, 404, "")
      end)

      assert {:error, :not_member} = HTTP.verify_membership("conv-1", "user-1")
    end
  end

  defp stub_req(fun) do
    Application.put_env(
      :whispr_calls,
      :messaging_http_req_options,
      plug: fun
    )
  end

  defp restore(_key, nil), do: :ok
  defp restore(key, value), do: Application.put_env(:whispr_calls, key, value)
end

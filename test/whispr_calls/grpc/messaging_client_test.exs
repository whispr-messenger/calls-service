defmodule WhisprCalls.Grpc.MessagingClientTest do
  use ExUnit.Case, async: false

  alias WhisprCalls.Grpc.MessagingClient
  alias WhisprCalls.Grpc.MessagingClient.HTTP
  alias WhisprCalls.Grpc.MessagingClient.Stub

  describe "dispatch via :messaging_client app env" do
    test "raises in :prod when :messaging_client is missing (no fail-open Stub)" do
      original_client = Application.get_env(:whispr_calls, :messaging_client)
      original_env = Application.get_env(:whispr_calls, :env)

      Application.delete_env(:whispr_calls, :messaging_client)
      Application.put_env(:whispr_calls, :env, :prod)

      on_exit(fn ->
        restore_env(:messaging_client, original_client)
        restore_env(:env, original_env)
      end)

      assert_raise RuntimeError, ~r/messaging_client is not configured in production/, fn ->
        MessagingClient.verify_membership("conv-1", "user-1")
      end
    end

    test "falls back to Stub outside :prod when :messaging_client is missing" do
      original_client = Application.get_env(:whispr_calls, :messaging_client)
      original_env = Application.get_env(:whispr_calls, :env)

      Application.delete_env(:whispr_calls, :messaging_client)
      Application.put_env(:whispr_calls, :env, :test)

      on_exit(fn ->
        restore_env(:messaging_client, original_client)
        restore_env(:env, original_env)
      end)

      assert {:ok, :member} = MessagingClient.verify_membership("conv-1", "user-1")
    end

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

    test "returns {:error, :not_member} on a non 200/403/404 status" do
      stub_req(fn conn ->
        Plug.Conn.send_resp(conn, 500, "boom")
      end)

      assert {:error, :not_member} = HTTP.verify_membership("conv-1", "user-1")
    end

    test "returns {:error, term} when Req returns a transport error" do
      stub_req(fn conn ->
        # Req.Test.transport_error/2 simulates a transport-level failure, which
        # Req surfaces as {:error, %Req.TransportError{}}.
        Req.Test.transport_error(conn, :timeout)
      end)

      assert {:error, _} = HTTP.verify_membership("conv-1", "user-1")
    end

    test "extracts member ids from {userId: ...} as well as {user_id: ...}" do
      stub_req(fn conn ->
        Req.Test.json(conn, %{
          "members" => [
            %{"userId" => "camel-1"},
            %{"user_id" => "snake-1"},
            %{"unknown" => "skip-me"}
          ]
        })
      end)

      assert {:ok, :member} = HTTP.verify_membership("conv-1", "camel-1")
      assert {:ok, :member} = HTTP.verify_membership("conv-1", "snake-1")
    end

    test "returns {:error, :not_member} when the body is not a list/map (defensive parse)" do
      stub_req(fn conn ->
        Req.Test.json(conn, %{"unexpected" => "shape"})
      end)

      assert {:error, :not_member} = HTTP.verify_membership("conv-1", "user-1")
    end

    test "supports a top-level list of member maps too" do
      stub_req(fn conn ->
        Req.Test.json(conn, [%{"user_id" => "user-1"}])
      end)

      assert {:ok, :member} = HTTP.verify_membership("conv-1", "user-1")
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

  # Variante qui delete plutot que de laisser nil dans l env (utilise par les
  # tests fail-open qui doivent garantir un etat propre apres run).
  defp restore_env(key, nil), do: Application.delete_env(:whispr_calls, key)
  defp restore_env(key, value), do: Application.put_env(:whispr_calls, key, value)
end

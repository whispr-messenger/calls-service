defmodule WhisprCallsWeb.UserChannelTest do
  use WhisprCallsWeb.ChannelCase, async: false

  alias WhisprCallsWeb.UserSocket

  test "user can join their own topic" do
    user_id = Ecto.UUID.generate()
    token = signed_test_jwt(user_id)

    {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert {:ok, _reply, _socket} = subscribe_and_join(socket, "user:#{user_id}", %{})
  end

  test "user cannot join someone else's topic" do
    attacker = Ecto.UUID.generate()
    victim = Ecto.UUID.generate()
    token = signed_test_jwt(attacker)

    {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert {:error, %{reason: "unauthorized"}} = subscribe_and_join(socket, "user:#{victim}", %{})
  end

  test "connect with an invalid token is rejected" do
    assert :error = connect(UserSocket, %{"token" => "not-a-jwt"})
  end

  test "connect without params is rejected" do
    assert :error = connect(UserSocket, %{})
  end

  test "unknown event on a joined channel is silently ignored" do
    user_id = Ecto.UUID.generate()
    token = signed_test_jwt(user_id)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _, socket} = subscribe_and_join(socket, "user:#{user_id}", %{})

    ref = push(socket, "anything_random", %{"foo" => 1})
    refute_reply ref, _, _, 50
    assert Process.alive?(socket.channel_pid)
  end

  defp signed_test_jwt(sub) do
    {alg, secret} = Application.fetch_env!(:whispr_calls, :jwt_signer)
    signer = Joken.Signer.create(alg, secret)
    {:ok, token, _} = Joken.encode_and_sign(%{"sub" => sub}, signer)
    token
  end
end

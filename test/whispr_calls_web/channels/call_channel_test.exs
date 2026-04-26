defmodule WhisprCallsWeb.CallChannelTest do
  use WhisprCallsWeb.ChannelCase, async: false
  import Mox
  alias WhisprCalls.Calls.LiveKitClientMock
  alias WhisprCallsWeb.UserSocket

  setup :verify_on_exit!

  test "participant can join call channel + broadcast mute" do
    initiator = Ecto.UUID.generate()
    expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
    expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "t"} end)

    {:ok, call, _} =
      WhisprCalls.Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
        type: "audio",
        participant_ids: []
      })

    token = signed_test_jwt(initiator)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _, socket} = subscribe_and_join(socket, "call:#{call.id}", %{})

    push(socket, "mute", %{"muted" => true})
    assert_broadcast "participant_muted", %{user_id: ^initiator, muted: true}
  end

  test "non-participant cannot join call channel" do
    initiator = Ecto.UUID.generate()
    expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
    expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "t"} end)

    {:ok, call, _} =
      WhisprCalls.Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
        type: "audio",
        participant_ids: []
      })

    other_user = Ecto.UUID.generate()
    token = signed_test_jwt(other_user)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    assert {:error, _} = subscribe_and_join(socket, "call:#{call.id}", %{})
  end

  test "mute with non-boolean payload is rejected with invalid_payload" do
    socket = join_as_initiator()
    ref = push(socket, "mute", %{"muted" => "yes"})
    assert_reply ref, :error, %{reason: "invalid_payload"}
  end

  test "unknown event does not crash the channel process" do
    socket = join_as_initiator()
    # Push something the channel doesn't know about - it must not crash.
    ref = push(socket, "totally_unknown_event", %{"foo" => "bar"})
    # No reply expected; the channel must still be alive afterwards.
    refute_reply ref, _, _, 50
    assert Process.alive?(socket.channel_pid)

    # Confirm the channel still works after the unknown event.
    push(socket, "mute", %{"muted" => true})
    assert_broadcast "participant_muted", %{muted: true}
  end

  defp join_as_initiator do
    initiator = Ecto.UUID.generate()
    expect(LiveKitClientMock, :create_room, fn _, _ -> {:ok, %{}} end)
    expect(LiveKitClientMock, :generate_access_token, fn _, _, _ -> {:ok, "t"} end)

    {:ok, call, _} =
      WhisprCalls.Calls.initiate_call(initiator, Ecto.UUID.generate(), %{
        type: "audio",
        participant_ids: []
      })

    token = signed_test_jwt(initiator)
    {:ok, socket} = connect(UserSocket, %{"token" => token})
    {:ok, _, socket} = subscribe_and_join(socket, "call:#{call.id}", %{})
    socket
  end

  defp signed_test_jwt(sub) do
    {alg, secret} = Application.fetch_env!(:whispr_calls, :jwt_signer)
    s = Joken.Signer.create(alg, secret)
    {:ok, t, _} = Joken.encode_and_sign(%{"sub" => sub}, s)
    t
  end
end

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

  defp signed_test_jwt(sub) do
    {alg, secret} = Application.fetch_env!(:whispr_calls, :jwt_signer)
    s = Joken.Signer.create(alg, secret)
    {:ok, t, _} = Joken.encode_and_sign(%{"sub" => sub}, s)
    t
  end
end

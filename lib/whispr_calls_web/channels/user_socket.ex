defmodule WhisprCallsWeb.UserSocket do
  @moduledoc """
  WebSocket entrypoint. Authenticates connections with the same JWT as the
  REST API (via the `token` param) and routes channel topics:

    * `user:*` — per-user event fanout (incoming call, call ended, etc.)
    * `call:*` — per-call signaling (mute, camera_off broadcasts)
  """
  use Phoenix.Socket

  channel "user:*", WhisprCallsWeb.UserChannel
  channel "call:*", WhisprCallsWeb.CallChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case verify_token(token) do
      {:ok, %{"sub" => user_id}} when is_binary(user_id) ->
        {:ok, assign(socket, :current_user_id, user_id)}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "user_socket:#{socket.assigns.current_user_id}"

  defp verify_token(token) do
    case Application.fetch_env!(:whispr_calls, :jwt_signer) do
      {alg, secret} when is_binary(alg) and is_binary(secret) ->
        signer = Joken.Signer.create(alg, secret)
        Joken.verify_and_validate(%{}, token, signer)

      %Joken.Signer{} = signer ->
        Joken.verify_and_validate(%{}, token, signer)

      strategy when is_atom(strategy) ->
        # See WhisprCallsWeb.Plugs.Authenticate for why we wrap the strategy
        # in the `JokenJwks` hook tuple rather than passing it directly.
        Joken.verify_and_validate(%{}, token, nil, %{}, [{JokenJwks, strategy: strategy}])
    end
  end
end

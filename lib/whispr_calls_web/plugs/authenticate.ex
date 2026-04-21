defmodule WhisprCallsWeb.Plugs.Authenticate do
  @moduledoc """
  Plug that verifies the `Authorization: Bearer <jwt>` header against the
  JWT signer configured for the current environment.

  * In `:test` and `:dev`, a simple HS256 secret is used (configured as
    `{algorithm, secret}` under `:whispr_calls, :jwt_signer`).
  * In `:prod`, the signer is resolved from the JWKS endpoint exposed by
    the auth-service (see `WhisprCalls.JwksStrategy`). The JWKS strategy
    module is provided as a second form of the `:jwt_signer` config.

  On successful verification the plug assigns `:current_user_id` on the
  conn with the value of the `sub` claim. On failure it returns a JSON
  `401` response and halts the pipeline.
  """
  import Plug.Conn

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, claims} <- verify_token(token) do
      assign(conn, :current_user_id, claims["sub"])
    else
      _ -> unauthorized(conn)
    end
  end

  defp verify_token(token) do
    case Application.fetch_env!(:whispr_calls, :jwt_signer) do
      {alg, secret} when is_binary(alg) and is_binary(secret) ->
        signer = Joken.Signer.create(alg, secret)
        Joken.verify_and_validate(%{}, token, signer)

      %Joken.Signer{} = signer ->
        Joken.verify_and_validate(%{}, token, signer)

      strategy when is_atom(strategy) ->
        # JWKS-backed strategy module (e.g. WhisprCalls.JwksStrategy).
        Joken.verify_and_validate(%{}, token, nil, %{}, [strategy])
    end
  end

  defp unauthorized(conn) do
    body = ~s({"error":"unauthorized"})

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, body)
    |> halt()
  end
end

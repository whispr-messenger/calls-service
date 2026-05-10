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
         {:ok, claims} <- verify_token(token),
         :ok <- assert_required_claims(claims) do
      assign(conn, :current_user_id, claims["sub"])
    else
      _ -> unauthorized(conn)
    end
  end

  # Joken n appelle le validator d un claim que s il est present dans le
  # payload (cf reduce_validations). Pour exiger la PRESENCE de iss/aud
  # quand la config les attend, on les check explicitement ici.
  defp assert_required_claims(claims) do
    cond do
      iss_required?() and not is_binary(claims["iss"]) -> {:error, :missing_iss}
      aud_required?() and is_nil(claims["aud"]) -> {:error, :missing_aud}
      true -> :ok
    end
  end

  defp iss_required?,
    do: is_binary(Application.get_env(:whispr_calls, :jwt_expected_issuer))

  defp aud_required?,
    do: is_binary(Application.get_env(:whispr_calls, :jwt_expected_audience))

  defp verify_token(token) do
    case Application.fetch_env!(:whispr_calls, :jwt_signer) do
      {alg, secret} when is_binary(alg) and is_binary(secret) ->
        signer = Joken.Signer.create(alg, secret)
        Joken.verify_and_validate(token_config(), token, signer)

      %Joken.Signer{} = signer ->
        Joken.verify_and_validate(token_config(), token, signer)

      strategy when is_atom(strategy) ->
        # JWKS-backed strategy module (e.g. WhisprCalls.JwksStrategy).
        # JokenJwks.DefaultStrategyTemplate generates a `JokenJwks` hook that
        # reads the JWT's `kid` header, asks the strategy for the matching
        # signer (in-memory ETS cache fed by the supervised GenServer) and
        # injects it into Joken. The hook takes the strategy as an option —
        # passing the bare strategy module would hit
        # `before_verify/2 is undefined or private` at runtime.
        Joken.verify_and_validate(token_config(), token, nil, %{}, [
          {JokenJwks, strategy: strategy}
        ])
    end
  end

  # Claim validation appliquee a chaque token entrant. On exige au minimum
  # un `exp` valide (tokens expirables). `iss` / `aud` sont enforces si la
  # config les declare, sinon on ne contraint pas (compatibilite test/dev).
  # Auparavant on passait %{} a Joken.verify_and_validate -> AUCUN check
  # standard => tokens expires acceptes, audience cross-service possible.
  defp token_config do
    Joken.Config.default_claims(skip: [:iss, :aud, :jti, :nbf])
    |> maybe_validate_iss()
    |> maybe_validate_aud()
  end

  defp maybe_validate_iss(config) do
    case Application.get_env(:whispr_calls, :jwt_expected_issuer) do
      nil ->
        config

      iss when is_binary(iss) ->
        # validate retourne false sur claim absent ou mismatch -> 401
        Joken.Config.add_claim(config, "iss", nil, fn
          ^iss -> true
          _ -> false
        end)
    end
  end

  defp maybe_validate_aud(config) do
    case Application.get_env(:whispr_calls, :jwt_expected_audience) do
      nil ->
        config

      aud when is_binary(aud) ->
        Joken.Config.add_claim(config, "aud", nil, fn
          ^aud -> true
          list when is_list(list) -> aud in list
          _ -> false
        end)
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

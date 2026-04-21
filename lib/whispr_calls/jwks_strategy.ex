defmodule WhisprCalls.JwksStrategy do
  @moduledoc """
  JWKS signer strategy used by `WhisprCallsWeb.Plugs.Authenticate` in
  production. Fetches public keys from the auth-service JWKS endpoint and
  caches them in-memory.

  The JWKS URL is read at runtime from `:whispr_calls, :jwks_url`, which
  `config/runtime.exs` populates from the `JWT_JWKS_URL` environment
  variable.
  """
  use JokenJwks.DefaultStrategyTemplate

  def init_opts(opts) do
    Keyword.merge(opts, jwks_url: Application.fetch_env!(:whispr_calls, :jwks_url))
  end
end

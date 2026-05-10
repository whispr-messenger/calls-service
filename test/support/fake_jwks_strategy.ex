defmodule WhisprCalls.FakeJwksStrategy do
  @moduledoc """
  Test-only JWKS strategy that implements the `JokenJwks.SignerMatchStrategy`
  behaviour without hitting the network. Returns a fixed HS256 signer for any
  kid — enough to exercise the `{JokenJwks, strategy: ...}` hook path through
  `Joken.verify_and_validate/5` that production uses.
  """

  @behaviour JokenJwks.SignerMatchStrategy

  @signer Joken.Signer.create("HS256", "fake_jwks_strategy_secret", %{"kid" => "fake-kid"})

  def signer, do: @signer

  @impl JokenJwks.SignerMatchStrategy
  def match_signer_for_kid(_kid, _opts), do: {:ok, @signer}
end

defmodule WhisprCalls.NoSignerJwksStrategy do
  @moduledoc """
  Test-only strategy that always fails to resolve a signer. Exercises the
  401 path — before WHISPR-1151 this branch produced a 500 because
  `Joken.verify_and_validate/5` was called with `[StrategyModule]` (a bare
  atom) instead of `[{JokenJwks, strategy: StrategyModule}]`.
  """

  @behaviour JokenJwks.SignerMatchStrategy

  @impl JokenJwks.SignerMatchStrategy
  def match_signer_for_kid(_kid, _opts), do: {:error, :kid_does_not_match}
end

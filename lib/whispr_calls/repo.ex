defmodule WhisprCalls.Repo do
  use Ecto.Repo,
    otp_app: :whispr_calls,
    adapter: Ecto.Adapters.Postgres
end

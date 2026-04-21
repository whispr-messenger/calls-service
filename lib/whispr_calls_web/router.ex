defmodule WhisprCallsWeb.Router do
  use WhisprCallsWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", WhisprCallsWeb do
    pipe_through :api
  end
end

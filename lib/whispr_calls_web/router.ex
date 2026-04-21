defmodule WhisprCallsWeb.Router do
  use WhisprCallsWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug WhisprCallsWeb.Plugs.Authenticate
  end

  pipeline :public do
    plug :accepts, ["json"]
  end

  scope "/calls/api/v1", WhisprCallsWeb do
    pipe_through :api

    post "/calls", CallController, :create
    get "/calls", CallController, :index
    get "/calls/:id", CallController, :show
    post "/calls/:id/accept", CallController, :accept
    post "/calls/:id/decline", CallController, :decline
    delete "/calls/:id", CallController, :end_call
  end

  scope "/health", WhisprCallsWeb do
    pipe_through :public

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end
end

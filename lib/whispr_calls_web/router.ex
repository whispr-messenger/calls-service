defmodule WhisprCallsWeb.Router do
  use WhisprCallsWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
    plug WhisprCallsWeb.Plugs.Authenticate
  end

  # Rate limit dedie a la creation d appels (WHISPR-1363). On l isole de la
  # pipeline :api pour ne pas brider les autres endpoints (accept, decline,
  # end, list) qui ont des semantiques tres differentes en termes d abus.
  pipeline :api_call_create do
    plug WhisprCallsWeb.Plugs.RateLimitCallCreation
  end

  pipeline :public do
    plug :accepts, ["json"]
  end

  scope "/calls/api/v1", WhisprCallsWeb do
    pipe_through :api

    get "/calls", CallController, :index
    get "/calls/:id", CallController, :show
    post "/calls/:id/accept", CallController, :accept
    post "/calls/:id/decline", CallController, :decline
    delete "/calls/:id", CallController, :end_call
  end

  scope "/calls/api/v1", WhisprCallsWeb do
    pipe_through [:api, :api_call_create]

    post "/calls", CallController, :create
  end

  scope "/health", WhisprCallsWeb do
    pipe_through :public

    get "/live", HealthController, :live
    get "/ready", HealthController, :ready
  end

  scope "/calls/webhooks", WhisprCallsWeb do
    pipe_through :public

    post "/livekit", LiveKitWebhookController, :handle
  end
end

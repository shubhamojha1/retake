defmodule RetakeWeb.Router do
  use RetakeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", RetakeWeb do
    pipe_through :api

    get "/health", HealthController, :show
  end
end

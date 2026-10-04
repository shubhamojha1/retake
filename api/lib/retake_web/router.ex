defmodule RetakeWeb.Router do
  use RetakeWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/api", RetakeWeb do
    pipe_through :api

    get "/health", HealthController, :show

    post "/videos", VideoController, :create
    get "/videos", VideoController, :index
    get "/videos/:id", VideoController, :show
  end

  # The file is video, not JSON: a player sends whatever Accept it likes, so no :api pipeline.
  scope "/api", RetakeWeb do
    get "/videos/:id/file", VideoController, :file
  end
end

defmodule Retake.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      RetakeWeb.Telemetry,
      Retake.Repo,
      {DNSCluster, query: Application.get_env(:retake, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Retake.PubSub},
      # Start a worker by calling: Retake.Worker.start_link(arg)
      # {Retake.Worker, arg},
      # Start to serve requests, typically the last entry
      RetakeWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Retake.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RetakeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

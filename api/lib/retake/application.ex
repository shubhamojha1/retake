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
      {Retake.Providers.Usage, name: Retake.Providers.Usage},
      # Video jobs and the other background work run under this supervisor.
      {Task.Supervisor, name: Retake.TaskSupervisor},
      # A job that was running when the app stopped will never finish: mark it failed.
      Supervisor.child_spec({Task, &fail_interrupted_videos/0},
        id: :fail_interrupted,
        restart: :temporary
      ),
      # Start to serve requests, typically the last entry
      RetakeWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Retake.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tests skip this: their database belongs to the test that owns the sandbox connection.
  defp fail_interrupted_videos do
    if Application.get_env(:retake, :fail_interrupted_on_boot, true),
      do: Retake.Videos.fail_interrupted()
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    RetakeWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

defmodule Vortex.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      VortexWeb.Telemetry,
      {DNSCluster, query: Application.get_env(:vortex, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Vortex.PubSub},
      {Task.Supervisor, name: Vortex.F1.TaskSupervisor},
      Vortex.F1.Cache.Server,
      Vortex.F1.Live.ReplayStore,
      Vortex.F1.Live.Supervisor,
      # Start to serve requests, typically the last entry
      VortexWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Vortex.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    VortexWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

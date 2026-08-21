defmodule NervesGate.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: NervesGate.PubSub},
      NervesGateWeb.Presence,
      {Task.Supervisor, name: NervesGate.TaskSupervisor},
      NervesGate.Alarms.Reporter,
      NervesGate.Platform,
      NervesGate.Device,
      NervesGate.Commissioning.Access,
      NervesGate.Internet.Manager,
      {DynamicSupervisor, name: NervesGate.Tailnet.DynamicSupervisor, strategy: :one_for_one},
      NervesGate.Tailnet.Manager,
      NervesGate.Internet.Monitor,
      NervesGate.Tailnet.Observer,
      NervesGate.Cluster.Manager,
      NervesGate.Setup,
      NervesGateWeb.Endpoint
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: NervesGate.Supervisor,
      max_restarts: 20,
      max_seconds: 60
    )
  end

  @impl true
  def config_change(changed, removed, _extra) do
    NervesGateWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

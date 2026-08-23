defmodule NervesGate.Backend do
  @moduledoc """
  Supervises the gateway backend in dependency order.

  Each gateway's `DeviceState.Server` owns its private firmware-slot settings,
  sequences its secret-free public reducer, and distributes that operation
  stream to connected peer clients.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    children = [
      {Task.Supervisor, name: NervesGate.TaskSupervisor},
      NervesGate.Alarms.Reporter,
      NervesGate.Commissioning.Access,
      NervesGate.Internet.Manager,
      NervesGate.Internet.Monitor,
      NervesGate.Tailnet.Manager,
      {DynamicSupervisor, name: NervesGate.Tailnet.DynamicSupervisor, strategy: :one_for_one},
      NervesGate.Tailnet.Observer,
      NervesGate.Cluster.Manager,
      NervesGate.DeviceState.Server,
      NervesGate.DeviceState.Client
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

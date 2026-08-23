defmodule NervesGate.Backend do
  @moduledoc """
  Supervises the gateway backend in dependency order.

  Runtime truth flows in one direction:

      Internet → Tailnet → Cluster → DeviceState

  `Configuration` owns one firmware-tagged settings snapshot and applies it
  through the runtime layers. `DeviceState` is the secret-free projection
  replicated to connected gateways.
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
      NervesGate.Configuration,
      NervesGate.DeviceState.Server,
      NervesGate.DeviceState.Client
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

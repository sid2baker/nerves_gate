defmodule NervesGate.Backend do
  @moduledoc """
  Supervises the gateway backend in dependency order.

  Runtime truth flows in one direction:

      Internet → Tailnet → Cluster → DeviceState

  `Setup` orchestrates commissioning commands but does not own runtime health.
  Each layer owns its local configuration, process lifecycle, observation, and
  alarms. `DeviceState` is the secret-free projection replicated to connected
  gateways.
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
      NervesGate.Settings.ChangeControl,
      NervesGate.Device,
      NervesGate.Commissioning.Access,
      NervesGate.Internet.Manager,
      NervesGate.Internet.Monitor,
      {DynamicSupervisor, name: NervesGate.Tailnet.DynamicSupervisor, strategy: :one_for_one},
      NervesGate.Tailnet.Manager,
      NervesGate.Tailnet.Observer,
      NervesGate.Tailnet.Configuration,
      NervesGate.Cluster.Manager,
      NervesGate.Setup,
      NervesGate.DeviceState.Server,
      NervesGate.DeviceState.Client
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

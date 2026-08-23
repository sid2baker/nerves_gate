defmodule NervesGate.Backend do
  @moduledoc """
  Supervises the gateway backend in dependency order.

  Each gateway's `DeviceState.Server` owns its private firmware-slot settings,
  sequences its secret-free public reducer, and distributes that operation
  stream to connected peer clients.
  """

  use Supervisor

  alias NervesGate.Storage

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    children =
      [
        {Task.Supervisor, name: NervesGate.TaskSupervisor},
        NervesGate.Alarms.Reporter,
        NervesGate.Commissioning.Access,
        NervesGate.Internet.Manager,
        NervesGate.Internet.Monitor
      ] ++
        tailnet_children() ++
        [
          NervesGate.Tailnet.Observer,
          NervesGate.SSH,
          NervesGate.Cluster.Manager,
          NervesGate.DeviceState.Server,
          NervesGate.DeviceState.Client
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp tailnet_children do
    if Application.fetch_env!(:nerves_gate, :tailscale_enabled) do
      paths = Application.fetch_env!(:nerves_gate, :tailscale_binaries)

      [
        {Tailscale,
         name: Tailscale,
         daemon_path: paths.daemon_path,
         cli_path: paths.cli_path,
         socket_path: "/run/tailscale/tailscaled.sock",
         tailscale_dir: Storage.path(["tailscale", "state"]),
         runtime_dir: "/run/tailscale_ex",
         tun: :kernel}
      ]
    else
      []
    end
  end
end

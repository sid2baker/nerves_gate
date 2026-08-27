defmodule NervesGate.Backend do
  @moduledoc """
  Supervises private gateway processes in dependency order.

  `NervesGate` is the only application-facing API. Configuration owns private
  settings transactions, while `DeviceState.Server` owns the canonical
  secret-free reducer and replication stream.
  """

  use Supervisor

  alias NervesGate.Storage

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    # Runtime infrastructure precedes the restartable public-state subtree.
    # DeviceState precedes every publisher so a rest-for-one restart produces
    # an empty projection followed by deterministic owner hydration.
    children =
      [
        {Registry, keys: :unique, name: NervesGate.EffectRegistry},
        {Task.Supervisor, name: NervesGate.TaskSupervisor}
      ] ++
        tailnet_children() ++
        [
          NervesGate.DeviceState.Server,
          fresh_owner(NervesGate.Firmware),
          fresh_owner(NervesGate.Commissioning),
          fresh_owner(NervesGate.Internet),
          fresh_owner(NervesGate.Tailnet),
          NervesGate.SSH.Supervisor,
          fresh_owner(NervesGate.SubnetRouter),
          NervesGate.Cluster.Supervisor,
          fresh_owner(NervesGate.Gateway.Configuration),
          NervesGate.Dependencies,
          NervesGate.Alarms.Runtime,
          NervesGate.DeviceState.Replica.Supervisor,
          NervesGate.Session.Supervisor
        ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  @spec start_owner(module()) :: GenServer.on_start()
  def start_owner(owner), do: owner.start_link(payload: owner.new(), name: owner)

  defp fresh_owner(owner) do
    %{id: owner, start: {__MODULE__, :start_owner, [owner]}}
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

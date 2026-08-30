defmodule NervesGate.Backend do
  @moduledoc """
  Supervises shared runtime infrastructure ahead of canonical gateway state.

  Device targets own their Tailscale runtime. Host builds never own the
  workstation daemon. Losing shared effect or target networking infrastructure
  rebuilds the state tree; ordinary resource-owner failures remain isolated.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    children =
      [
        {Registry, keys: :unique, name: NervesGate.EffectRegistry},
        {Task.Supervisor, name: NervesGate.TaskSupervisor}
      ] ++ tailscale_children() ++ [NervesGate.Backend.StateTree]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  if Mix.target() == :host do
    defp tailscale_children, do: []
  else
    defp tailscale_children do
      paths = Application.fetch_env!(:nerves_gate, :tailscale_binaries)

      [
        {Tailscale,
         name: Tailscale,
         daemon_path: paths.daemon_path,
         cli_path: paths.cli_path,
         socket_path: "/run/tailscale/tailscaled.sock",
         tailscale_dir: NervesGate.Storage.path(["tailscale", "state"]),
         runtime_dir: "/run/tailscale_ex",
         tun: :kernel}
      ]
    end
  end
end

defmodule NervesGate.Backend.StateTree do
  @moduledoc """
  Keeps the authoritative state stream ahead of owners and fleet replication.

  A DeviceState failure deliberately rebuilds every owner so each publishes a
  complete fresh slice under the new boot ID. An individual owner failure is
  isolated inside `Backend.Owners` and does not restart clients or Fleet.
  """

  use Supervisor

  @owners %{
    firmware: NervesGate.Firmware,
    configuration: NervesGate.Gateway.Configuration,
    commissioning: NervesGate.Commissioning,
    internet: NervesGate.Internet,
    tailnet: NervesGate.Tailnet,
    subnet_router: NervesGate.SubnetRouter,
    ssh: NervesGate.SSH,
    cluster: NervesGate.Cluster,
    alarms: NervesGate.Alarms
  }

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    children = [
      {NervesGate.DeviceState.Server, owners: @owners},
      NervesGate.Backend.Owners,
      NervesGate.Fleet
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule NervesGate.Backend.Owners do
  @moduledoc """
  Supervises independent external-resource owners with `:one_for_one`.

  Configuration is the sole writer of accepted settings. Restarted owners read
  that accepted intent and reconcile it with external reality themselves, so a
  resource failure never requires a configuration-process restart.
  """

  use Supervisor

  alias NervesGate.Gateway.{Configuration, Settings}
  alias NervesGate.Gateway.Configuration.Context

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    children = [
      NervesGate.Alarms,
      {NervesGate.Firmware, configuration_busy: &Configuration.busy?/0},
      {NervesGate.Commissioning, load_desired: &commissioning_desired/0},
      {NervesGate.Internet, load_current: &accepted_internet/0},
      NervesGate.Tailnet,
      {NervesGate.SSH.Supervisor, load_enabled: &accepted_ssh/0},
      {NervesGate.SubnetRouter, load_desired: &accepted_subnet_router/0},
      {NervesGate.Cluster, load_group: &accepted_cluster_group/0},
      {Configuration, firmware_busy: &NervesGate.Firmware.busy?/0}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp commissioning_desired do
    settings = accepted_settings()

    if not settings["configured"] or Application.get_env(:nerves_gate, :local_dashboard, false) do
      %{mode: :commissioning, uplink: Context.active_interface(settings)}
    else
      %{mode: :disabled, uplink: nil}
    end
  end

  defp accepted_internet, do: accepted_settings() |> Settings.internet()
  defp accepted_ssh, do: accepted_settings() |> Settings.ssh_enabled()
  defp accepted_cluster_group, do: accepted_settings() |> Settings.cluster_group()

  defp accepted_subnet_router do
    settings = accepted_settings()
    desired = Settings.subnet_router(settings)
    %{enabled: desired["enabled"], routes: desired["routes"]}
  end

  defp accepted_settings, do: Configuration.current()
end

defmodule NervesGate.Backend do
  @moduledoc """
  Supervises the infrastructure required by every gateway owner.

  Effect infrastructure and the target Tailscale runtime precede the complete
  public-state tree. Losing any of them rebuilds DeviceState and every process
  that depends on it; failures inside one publisher branch stay in that branch.
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
    # Host builds observe injected or workstation state but never own the
    # workstation's Tailscale daemon. Every device target always owns it.
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
  Keeps DeviceState ahead of every publisher, replica, and client session.

  A DeviceState failure discards the projection and rebuilds all downstream
  processes. Publisher failures are isolated by `Backend.Publishers`.
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
    alarms: NervesGate.Alarms.Runtime
  }

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    children = [
      {NervesGate.DeviceState.Server, owners: @owners},
      NervesGate.Backend.Publishers,
      NervesGate.DeviceState.Replica.Supervisor,
      {DynamicSupervisor, name: NervesGate.Session.DynamicSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule NervesGate.Backend.Publishers do
  @moduledoc """
  Isolates independent DeviceState publisher failure domains.

  Firmware, connection ownership, and alarm projection can recover without
  restarting one another or disconnecting every client session.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    children = [
      {NervesGate.Firmware, configuration_busy: &NervesGate.Gateway.Configuration.busy?/0},
      NervesGate.Backend.Connection,
      NervesGate.Alarms.Runtime
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end

defmodule NervesGate.Backend.Connection do
  @moduledoc """
  Supervises the connected-runtime owners and durable settings workflow.

  The ordering is intentional: a resource-owner failure also restarts the
  later configuration owner, which reloads accepted intent and replays it into
  the reconstructed runtime. This cascade is confined to connection resources.
  """

  use Supervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: __MODULE__)
  end

  @impl true
  def init(_options) do
    children = [
      NervesGate.Commissioning,
      NervesGate.Internet,
      NervesGate.Tailnet,
      {NervesGate.SSH.Supervisor,
       load_enabled: fn ->
         NervesGate.Gateway.Configuration.current()
         |> NervesGate.Gateway.Settings.ssh_enabled()
       end},
      NervesGate.SubnetRouter,
      {NervesGate.Cluster.Supervisor,
       load_group: fn ->
         NervesGate.Gateway.Configuration.current()
         |> NervesGate.Gateway.Settings.cluster_group()
       end},
      {NervesGate.Gateway.Configuration, firmware_busy: &NervesGate.Firmware.busy?/0}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

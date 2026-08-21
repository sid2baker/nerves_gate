defmodule NervesGate.Status do
  @moduledoc "Builds the secret-free dashboard snapshot."

  alias NervesGate.Alarms
  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Device
  alias NervesGate.Identity
  alias NervesGate.Internet.Hardware
  alias NervesGate.Internet.Manager, as: InternetManager
  alias NervesGate.Internet.Monitor
  alias NervesGate.Setup
  alias NervesGate.Tailnet.Observer

  @spec snapshot() :: map()
  def snapshot do
    internet = safe(Monitor, :status, offline_internet())
    tailnet = safe(Observer, :status, offline_tailnet())
    cluster = safe(ClusterManager, :status, singular_cluster())
    connected = Enum.map(cluster.connected, &to_string/1)
    node = if(cluster.node, do: to_string(cluster.node))

    # Compatibility: remove the network/distribution/cluster compatibility shape during
    # the NervesGateWeb refactor. Distribution is now an implementation detail
    # of Cluster and no credential is ever included here.
    %{
      device: safe(Device, :get, %{"name" => Identity.get().hostname, "history" => []}),
      identity: Identity.get(),
      setup: safe(Setup, :status, %{phase: :internet, ready: false, recovery: false}),
      network: %{
        configuration: safe(InternetManager, :status, %{}),
        connectivity: internet,
        interfaces: Hardware.interfaces()
      },
      tailnet: tailnet,
      layers: layer_states(internet, tailnet, cluster),
      people_count: safe(NervesGateWeb.Presence, :count, 0),
      distribution: %{online: cluster.online, node: node, connected: connected},
      cluster: %{
        enabled: cluster.enabled,
        online: cluster.online,
        running: cluster.online,
        node: node,
        connected: connected,
        nodes: tailnet.nodes
      },
      alarms: Alarms.active(),
      diagnostics: diagnostics()
    }
  end

  @spec api_snapshot() :: map()
  def api_snapshot, do: snapshot() |> json_safe()

  @doc "Returns dependency-aware operational states without persisting runtime facts."
  @spec layer_states(map(), map(), map()) :: map()
  def layer_states(internet, tailnet, cluster) do
    internet_state = if internet.online, do: :ok, else: :failed
    tailnet_state = layer_state(internet.online, tailnet.online)

    cluster_state =
      cond do
        not cluster.enabled -> :disabled
        not internet.online or not tailnet.online -> :blocked
        cluster.online -> :ok
        true -> :failed
      end

    %{internet: internet_state, tailnet: tailnet_state, cluster: cluster_state}
  end

  defp layer_state(false, _online), do: :blocked
  defp layer_state(true, true), do: :ok
  defp layer_state(true, false), do: :failed

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp json_safe(value), do: value

  defp diagnostics do
    {uptime, _since_last_call} = :erlang.statistics(:wall_clock)

    %{
      target: Nerves.Runtime.mix_target(),
      uptime_seconds: div(uptime, 1_000),
      firmware_version: Application.spec(:nerves_gate, :vsn) |> to_string(),
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      memory_bytes: :erlang.memory(:total)
    }
  end

  defp safe(module, function, fallback) do
    apply(module, function, [])
  catch
    :exit, _reason -> fallback
    _kind, _reason -> fallback
  end

  defp offline_internet do
    %{interface: nil, online: false, ready: false, reason: :unavailable, checks: %{}}
  end

  defp offline_tailnet do
    %{
      online: false,
      authenticated: false,
      hostname: nil,
      ipv4: nil,
      peers: [],
      nodes: [],
      error: :offline
    }
  end

  defp singular_cluster do
    %{enabled: false, online: false, node: nil, connected: []}
  end
end

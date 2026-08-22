defmodule NervesGate.Status do
  @moduledoc "Compatibility projection over canonical local device data and remote copies."

  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Device
  alias NervesGate.DeviceState.Client
  alias NervesGate.DeviceState.Data
  alias NervesGate.DeviceState.Server
  alias NervesGate.Identity
  alias NervesGate.Internet.Hardware
  alias NervesGate.Internet.Manager, as: InternetManager
  alias NervesGate.Internet.Monitor
  alias NervesGate.Settings
  alias NervesGate.Setup
  alias NervesGate.Tailnet.Observer

  @spec snapshot() :: map()
  def snapshot do
    data = safe(Server, :data, fallback_data())
    replicas = safe(Client, :replicas, %{})
    internet_diagnostics = safe(Monitor, :status, offline_internet())
    tailnet_diagnostics = safe(Observer, :status, offline_tailnet())
    cluster_diagnostics = safe(ClusterManager, :status, %{})
    cluster = cluster_compatibility(data, cluster_diagnostics)

    # Compatibility: remove this legacy shape during the NervesGateWeb refactor.
    # Local operational truth and all remote state now come from DeviceState.
    %{
      device: compatibility_device(data),
      identity: Identity.get(),
      setup: safe(Setup, :status, %{phase: :internet, ready: false, recovery: false}),
      settings: safe(Settings, :status, %{pending: nil, maintenance: [], last_error: nil}),
      network: %{
        configuration: safe(InternetManager, :status, %{}),
        connectivity: compatibility_internet(data, internet_diagnostics),
        interfaces: Hardware.interfaces()
      },
      tailnet: compatibility_tailnet(data, tailnet_diagnostics),
      layers: layers(data),
      people_count: safe(NervesGateWeb.Presence, :count, 0),
      distribution: Map.take(cluster, [:online, :node, :connected]),
      cluster: Map.put(cluster, :nodes, cluster_nodes(data, replicas)),
      alarms: data.alarms,
      device_state: %{
        local: Data.to_map(data),
        replicas: Map.new(replicas, fn {id, replica} -> {id, replica_map(replica)} end)
      },
      diagnostics: diagnostics(data)
    }
  end

  @spec api_snapshot() :: map()
  def api_snapshot, do: snapshot() |> json_safe()

  defp layers(data) do
    %{
      internet: data.internet.status |> layer_state(),
      tailnet: data.tailnet.status |> layer_state(),
      cluster: data.cluster.status |> layer_state()
    }
  end

  defp layer_state(:online), do: :ok
  defp layer_state(:offline), do: :failed
  defp layer_state(status) when status in [:failed, :blocked, :disabled], do: status
  defp layer_state(_unknown), do: :failed

  defp compatibility_device(data) do
    profile = safe(Device, :get, %{"history" => []})
    Map.put(profile, "name", data.name)
  end

  defp compatibility_internet(data, diagnostics) do
    online = data.internet.status == :online

    diagnostics
    |> Map.put(:online, online)
    |> Map.put(:ready, online)
    |> Map.put(:reason, data.internet.reason)
  end

  defp compatibility_tailnet(data, diagnostics) do
    %{
      online: data.tailnet.status == :online,
      authenticated: data.tailnet.authenticated,
      hostname: data.tailnet.hostname,
      ipv4: data.tailnet.ipv4,
      peers: Map.get(diagnostics, :peers, []),
      nodes: Map.get(diagnostics, :nodes, []),
      error: if(data.tailnet.status == :online, do: nil, else: data.tailnet.status)
    }
  end

  defp cluster_compatibility(data, diagnostics) do
    online = data.cluster.status == :online

    %{
      enabled: data.cluster.enabled,
      group: data.cluster.group,
      online: online,
      running: online,
      node: data.cluster.node,
      connected: data.cluster.connected,
      candidates: Map.get(diagnostics, :candidates, []),
      groups: Map.get(diagnostics, :groups, [])
    }
  end

  defp cluster_nodes(data, replicas) do
    local = device_node(data, true, true, nil)

    remote =
      replicas
      |> Map.values()
      |> Enum.map(fn replica ->
        device_node(replica.data, false, replica.connected, replica.last_seen_at)
      end)

    [local | remote]
    |> Enum.reject(&is_nil(&1.ipv4))
    |> Enum.sort_by(&{not &1.self, &1.hostname || ""})
  end

  defp device_node(data, self?, connected?, last_seen_at) do
    %{
      hostname: data.tailnet.hostname || data.name,
      ipv4: data.tailnet.ipv4,
      online: connected? and data.tailnet.status == :online,
      self: self?,
      stale: not connected?,
      last_seen_at: last_seen_at
    }
  end

  defp replica_map(replica) do
    %{
      data: Data.to_map(replica.data),
      node: to_string(replica.node),
      boot_id: replica.boot_id,
      revision: replica.revision,
      connected: replica.connected,
      last_seen_at: replica.last_seen_at
    }
  end

  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(value) when is_struct(value), do: value |> Map.from_struct() |> json_safe()

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, json_safe(item)} end)
  end

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value)
  defp json_safe(value) when is_pid(value) or is_reference(value), do: inspect(value)
  defp json_safe(value), do: value

  defp diagnostics(data) do
    {uptime, _since_last_call} = :erlang.statistics(:wall_clock)

    %{
      target: Nerves.Runtime.mix_target(),
      uptime_seconds: div(uptime, 1_000),
      firmware_version: data.firmware_version,
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      memory_bytes: :erlang.memory(:total)
    }
  end

  defp safe(module, function, fallback) do
    apply(module, function, [])
  catch
    :exit, _reason -> fallback
  end

  defp fallback_data do
    identity = Identity.get()

    Data.new(
      device_id: identity.machine_id,
      name: identity.hostname,
      firmware_version: Application.spec(:nerves_gate, :vsn) |> to_string()
    )
  end

  defp offline_internet do
    %{interface: nil, online: false, ready: false, reason: :unavailable, checks: %{}}
  end

  defp offline_tailnet do
    %{peers: [], nodes: []}
  end
end

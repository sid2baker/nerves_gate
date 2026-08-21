defmodule NervesGate.Status do
  @moduledoc "Compatibility projection over authoritative local public data and peer replicas."

  alias NervesGate.Device
  alias NervesGate.DeviceState.Client
  alias NervesGate.DeviceState.Public
  alias NervesGate.DeviceState.Server
  alias NervesGate.Identity
  alias NervesGate.Internet.Hardware
  alias NervesGate.Internet.Manager, as: InternetManager
  alias NervesGate.Internet.Monitor
  alias NervesGate.Setup

  @spec snapshot() :: map()
  def snapshot do
    public = safe(Server, :public, fallback_public())
    replicas = safe(Client, :replicas, %{})
    internet_diagnostics = safe(Monitor, :status, offline_internet())
    cluster = cluster_compatibility(public)

    # Compatibility: remove this legacy shape during the NervesGateWeb refactor.
    # Local operational truth and all remote state now come from DeviceState.
    %{
      device: compatibility_device(public),
      identity: Identity.get(),
      setup: safe(Setup, :status, %{phase: :internet, ready: false, recovery: false}),
      network: %{
        configuration: safe(InternetManager, :status, %{}),
        connectivity: compatibility_internet(public, internet_diagnostics),
        interfaces: Hardware.interfaces()
      },
      tailnet: compatibility_tailnet(public),
      layers: public_layers(public),
      people_count: safe(NervesGateWeb.Presence, :count, 0),
      distribution: Map.take(cluster, [:online, :node, :connected]),
      cluster: Map.put(cluster, :nodes, cluster_nodes(public, replicas)),
      alarms: public.alarms,
      device_state: %{
        local: Public.to_map(public),
        replicas: Map.new(replicas, fn {id, replica} -> {id, replica_map(replica)} end)
      },
      diagnostics: diagnostics(public)
    }
  end

  @spec api_snapshot() :: map()
  def api_snapshot, do: snapshot() |> json_safe()

  defp public_layers(public) do
    %{
      internet: public.internet.status |> public_layer_state(),
      tailnet: public.tailnet.status |> public_layer_state(),
      cluster: public.cluster.status |> public_layer_state()
    }
  end

  defp public_layer_state(:online), do: :ok
  defp public_layer_state(:offline), do: :failed
  defp public_layer_state(status) when status in [:failed, :blocked, :disabled], do: status
  defp public_layer_state(_unknown), do: :failed

  defp compatibility_device(public) do
    profile = safe(Device, :get, %{"history" => []})
    Map.put(profile, "name", public.name)
  end

  defp compatibility_internet(public, diagnostics) do
    online = public.internet.status == :online

    diagnostics
    |> Map.put(:online, online)
    |> Map.put(:ready, online)
    |> Map.put(:reason, public.internet.reason)
  end

  defp compatibility_tailnet(public) do
    %{
      online: public.tailnet.status == :online,
      authenticated: public.tailnet.authenticated,
      hostname: public.tailnet.hostname,
      ipv4: public.tailnet.ipv4,
      peers: [],
      nodes: [],
      error: if(public.tailnet.status == :online, do: nil, else: public.tailnet.status)
    }
  end

  defp cluster_compatibility(public) do
    online = public.cluster.status == :online

    %{
      enabled: public.cluster.enabled,
      online: online,
      running: online,
      node: public.cluster.node,
      connected: public.cluster.connected
    }
  end

  defp cluster_nodes(public, replicas) do
    local = public_node(public, true, true, nil)

    remote =
      replicas
      |> Map.values()
      |> Enum.map(fn replica ->
        public_node(replica.data, false, replica.connected, replica.last_seen_at)
      end)

    [local | remote]
    |> Enum.reject(&is_nil(&1.ipv4))
    |> Enum.sort_by(&{not &1.self, &1.hostname || ""})
  end

  defp public_node(public, self?, connected?, last_seen_at) do
    %{
      hostname: public.tailnet.hostname || public.name,
      ipv4: public.tailnet.ipv4,
      online: connected? and public.tailnet.status == :online,
      self: self?,
      stale: not connected?,
      last_seen_at: last_seen_at
    }
  end

  defp replica_map(replica) do
    %{
      data: Public.to_map(replica.data),
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

  defp diagnostics(public) do
    {uptime, _since_last_call} = :erlang.statistics(:wall_clock)

    %{
      target: Nerves.Runtime.mix_target(),
      uptime_seconds: div(uptime, 1_000),
      firmware_version: public.firmware_version,
      otp_release: List.to_string(:erlang.system_info(:otp_release)),
      memory_bytes: :erlang.memory(:total)
    }
  end

  defp safe(module, function, fallback) do
    apply(module, function, [])
  catch
    _kind, _reason -> fallback
  end

  defp fallback_public do
    identity = Identity.get()

    %Public{
      device_id: identity.machine_id,
      name: identity.hostname,
      boot_id: "starting",
      firmware_version: Application.spec(:nerves_gate, :vsn) |> to_string()
    }
  end

  defp offline_internet do
    %{interface: nil, online: false, ready: false, reason: :unavailable, checks: %{}}
  end
end

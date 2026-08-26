defmodule NervesGateWeb.StatusLive.View do
  @moduledoc "Pure rendering projection over canonical DeviceState fleet snapshots."

  @spec build(map(), non_neg_integer(), String.t() | nil) :: map()
  def build(fleet, people_count, selected_device_id) do
    local = node_view(fleet.local.state, local_metadata(fleet.local))

    nodes =
      [local | remote_nodes(fleet.replicas)]
      |> Enum.sort_by(&node_sort_key/1)

    selected = Enum.find(nodes, local, &(&1.id == selected_device_id))
    state = fleet.local.state
    cluster = state.cluster || empty_cluster()

    %{
      configuration: state.configuration || empty_configuration(),
      internet: state.internet || empty_internet(),
      subnet_router: state.subnet_router || empty_subnet_router(),
      ssh: state.ssh || empty_ssh(),
      people_count: people_count,
      local: local,
      selected: selected,
      nodes: nodes,
      metrics: %{
        known_gateways: length(nodes),
        online_gateways: Enum.count(nodes, & &1.connected),
        connected_peers: length(cluster.connected),
        alarms: Enum.sum(Enum.map(nodes, &length(&1.alarms)))
      }
    }
  end

  defp local_metadata(snapshot) do
    [
      self: true,
      connected: true,
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      last_seen_at: nil
    ]
  end

  defp remote_nodes(replicas) do
    Enum.map(replicas, fn {_device_id, replica} ->
      node_view(replica.state,
        self: false,
        connected: replica.connected,
        boot_id: replica.boot_id,
        revision: replica.revision,
        last_seen_at: replica.last_seen_at
      )
    end)
  end

  defp node_view(state, metadata) do
    connected = Keyword.fetch!(metadata, :connected)
    device = state.device || empty_device()
    display_name = configuration_name(state.configuration, device.name)
    tailnet = state.tailnet || empty_tailnet()
    cluster = state.cluster || empty_cluster()
    internet = state.internet || empty_internet()
    subnet_router = state.subnet_router || empty_subnet_router()
    ssh = state.ssh || empty_ssh()
    alarms = state.alarms || []
    status = node_status(internet, tailnet, cluster, connected)

    %{
      id: device.device_id,
      device: device,
      internet: internet,
      tailnet: tailnet,
      subnet_router: subnet_router,
      ssh: ssh,
      cluster: cluster,
      alarms: alarms,
      name: display_name,
      firmware_version: device.firmware_version,
      hostname: tailnet.hostname || device.name,
      ipv4: tailnet.ipv4,
      self: Keyword.fetch!(metadata, :self),
      connected: connected,
      stale: not connected,
      status: status,
      tone: status_tone(status),
      node: cluster.node,
      boot_id: Keyword.fetch!(metadata, :boot_id),
      revision: Keyword.fetch!(metadata, :revision),
      last_seen_at: Keyword.get(metadata, :last_seen_at),
      url: node_url(tailnet.ipv4),
      layers: [
        layer(:internet, internet.state, internet.reason),
        layer(:tailnet, tailnet.state, tailnet.error),
        layer(:cluster, cluster.state, cluster.state)
      ]
    }
  end

  defp configuration_name(%{current: %{name: name}}, _fallback) when is_binary(name), do: name
  defp configuration_name(_configuration, fallback), do: fallback

  defp node_status(_internet, _tailnet, _cluster, false), do: :stale

  defp node_status(internet, tailnet, cluster, true) do
    cond do
      not internet.online -> :degraded
      not tailnet.online -> :degraded
      cluster.enabled and not cluster.online -> :degraded
      true -> :online
    end
  end

  defp layer(name, state, observed) do
    %{name: name, status: state, observed: observed, tone: layer_tone(state)}
  end

  defp status_tone(:online), do: :good
  defp status_tone(:degraded), do: :bad
  defp status_tone(:stale), do: :warning

  defp layer_tone(:online), do: :good
  defp layer_tone(:disabled), do: :neutral

  defp layer_tone(state) when state in [:blocked, :needs_auth, :connecting, :reconciling],
    do: :warning

  defp layer_tone(_state), do: :bad

  defp node_sort_key(node), do: {not node.self, not node.connected, String.downcase(node.name)}

  defp node_url(nil), do: nil
  defp node_url(ipv4), do: "http://#{ipv4}/"

  defp empty_device,
    do: %{device_id: "starting", name: "Starting", firmware_version: "unknown"}

  defp empty_configuration,
    do: %{configured: false, current: %{}, pending: nil, last_error: nil}

  defp empty_internet,
    do: %{state: :unconfigured, interface: nil, online: false, reason: :starting, checks: %{}}

  defp empty_tailnet,
    do: %{state: :disabled, online: false, hostname: nil, ipv4: nil, error: :starting}

  defp empty_cluster,
    do: %{state: :disabled, enabled: false, online: false, group: nil, node: nil, connected: []}

  defp empty_subnet_router,
    do: %{state: :disabled, enabled: false, routes: [], observed: %{}}

  defp empty_ssh,
    do: %{state: :disabled, enabled: false, address: nil, port: 22}
end

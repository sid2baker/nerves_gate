defmodule NervesGateWeb.StatusLive.View do
  @moduledoc "Pure rendering projection over canonical device data and local replica metadata."

  alias NervesGate.DeviceState.Data

  @spec build(map(), map(), String.t() | nil) :: map()
  def build(state, context, selected_device_id) do
    local = local_node(state)
    nodes = [local | remote_nodes(state.replicas)] |> Enum.sort_by(&node_sort_key/1)
    selected = Enum.find(nodes, local, &(&1.id == selected_device_id))

    %{
      setup: context.setup,
      profile: Map.put(context.profile, "name", state.data.name),
      identity: context.identity,
      internet: context.internet,
      network_configuration: context.network_configuration,
      tailnet: context.tailnet,
      cluster: cluster_view(context.cluster),
      diagnostics: context.diagnostics,
      people_count: context.people_count,
      local: local,
      selected: selected,
      nodes: nodes,
      metrics: %{
        known_gateways: length(nodes),
        online_gateways: Enum.count(nodes, & &1.connected),
        connected_peers: length(state.data.cluster.connected),
        alarms: Enum.sum(Enum.map(nodes, &length(&1.data.alarms)))
      }
    }
  end

  defp local_node(state) do
    node_view(state.data,
      self: true,
      connected: true,
      node: state.data.cluster.node,
      boot_id: state.boot_id,
      revision: state.revision,
      last_seen_at: nil
    )
  end

  defp remote_nodes(replicas) do
    Enum.map(replicas, fn {_device_id, replica} ->
      node_view(replica.data,
        self: false,
        connected: replica.connected,
        node: replica.node,
        boot_id: replica.boot_id,
        revision: replica.revision,
        last_seen_at: replica.last_seen_at
      )
    end)
  end

  defp node_view(%Data{} = data, metadata) do
    connected = Keyword.fetch!(metadata, :connected)
    status = node_status(data, connected)

    %{
      id: data.device_id,
      data: data,
      name: data.name,
      hostname: data.tailnet.hostname || data.name,
      ipv4: data.tailnet.ipv4,
      self: Keyword.fetch!(metadata, :self),
      connected: connected,
      stale: not connected,
      status: status,
      tone: status_tone(status),
      node: Keyword.get(metadata, :node),
      boot_id: Keyword.fetch!(metadata, :boot_id),
      revision: Keyword.fetch!(metadata, :revision),
      last_seen_at: Keyword.get(metadata, :last_seen_at),
      url: node_url(data.tailnet.ipv4),
      layers: [
        layer(:internet, data.internet.status, data.internet.reason),
        layer(:tailnet, data.tailnet.status, data.tailnet.observed_status),
        layer(:cluster, data.cluster.status, data.cluster.runtime_status)
      ]
    }
  end

  defp node_status(_data, false), do: :stale

  defp node_status(data, true) do
    cond do
      data.internet.status != :online -> :degraded
      data.tailnet.status != :online -> :degraded
      data.cluster.enabled and data.cluster.status != :online -> :degraded
      true -> :online
    end
  end

  defp layer(name, status, observed) do
    %{name: name, status: status, observed: observed, tone: layer_tone(status)}
  end

  defp status_tone(:online), do: :good
  defp status_tone(:degraded), do: :bad
  defp status_tone(:stale), do: :warning

  defp layer_tone(:online), do: :good
  defp layer_tone(:disabled), do: :neutral
  defp layer_tone(:blocked), do: :warning
  defp layer_tone(_status), do: :bad

  defp cluster_view(cluster) do
    cluster
    |> Map.put_new(:group, nil)
    |> Map.put_new(:groups, [])
    |> Map.put_new(:candidates, [])
  end

  defp node_sort_key(node), do: {not node.self, not node.connected, String.downcase(node.name)}

  defp node_url(nil), do: nil
  defp node_url(ipv4), do: "http://#{ipv4}/"
end

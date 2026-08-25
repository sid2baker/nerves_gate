defmodule NervesGate do
  @moduledoc """
  Public Command/Event/State boundary.

  Commands are routed to their owning subsystem. Every consumer reads the same
  typed DeviceState snapshots and applies the same ordered public events.
  """

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.Replica.Supervisor, as: ReplicaSupervisor
  alias NervesGate.Gateway.Configuration

  @doc "Returns the atomic local DeviceState snapshot."
  def snapshot, do: DeviceState.snapshot()

  @doc "Atomically subscribes the caller to future local DeviceState events."
  def subscribe, do: DeviceState.subscribe()

  @doc "Returns the independently versioned local and remote gateway snapshots."
  def fleet do
    %{local: snapshot(), replicas: ReplicaSupervisor.replicas()}
  end

  @doc "Subscribes to local events and remote-replica changes, then returns the fleet."
  def subscribe_fleet do
    :ok = Phoenix.PubSub.subscribe(NervesGate.PubSub, "device_state")

    {:ok, local} = subscribe()
    {:ok, %{local: local, replicas: ReplicaSupervisor.replicas()}}
  end

  @doc "Purely applies one ordered public event to canonical state."
  def apply_event(state, event), do: NervesGate.DeviceState.State.apply_event(state, event)

  @doc "Returns whether first-time commissioning is complete."
  def configured? do
    case snapshot().state.configuration do
      %{configured: configured} -> configured
      _unhydrated -> false
    end
  end

  @doc "Returns the dashboard actor represented by a remote Tailnet address."
  def actor_for_ip(remote_ip) do
    peer =
      snapshot().state.tailnet
      |> case do
        %{peers: peers} -> Enum.find(peers, &(&1.ipv4 == remote_ip))
        _unhydrated -> nil
      end

    %{ip: remote_ip, name: (peer && peer.hostname) || "tailnet user"}
  end

  @doc "Begins a Tailnet-only or Cluster-only guarded settings change."
  def begin_change(scope, connection_id, timeout),
    do: Configuration.begin_change(scope, connection_id, timeout)

  @doc "Stages Internet settings during complete commissioning."
  def stage_internet(params, connection_id, timeout),
    do: Configuration.stage_internet(params, connection_id, timeout)

  @doc "Updates Internet settings in a complete candidate."
  def update_internet(id, params), do: Configuration.update_internet(id, params)

  @doc "Stages Tailnet settings in the active candidate."
  def stage_tailnet(id, params), do: Configuration.stage_tailnet(id, params)

  @doc "Stages Cluster settings in the active candidate."
  def stage_cluster(id, params), do: Configuration.stage_cluster(id, params)

  @doc "Accepts a complete candidate from a fresh Tailnet connection."
  def confirm(id, connection), do: Configuration.confirm(id, connection)

  @doc "Rejects the active candidate and restores accepted settings."
  def revert(id), do: Configuration.revert(id)

  @doc "Changes accepted subnet-router settings."
  def configure_subnet_router(enabled, routes),
    do: Configuration.configure_subnet_router(enabled, routes)

  @doc "Changes accepted Tailnet-only Remote IEx settings."
  def configure_ssh(enabled), do: Configuration.configure_ssh(enabled)

  @doc "Returns Tailnet-only gateway discovery metadata from canonical state."
  def discovery do
    state = snapshot().state
    device = state.device || %{}
    tailnet = state.tailnet
    cluster = state.cluster

    %{
      gateway_id: Map.get(device, :device_id),
      hostname: (tailnet && tailnet.hostname) || Map.get(device, :name),
      cluster_group: cluster && cluster.group
    }
  end

  @doc "Returns the versioned, secret-free canonical status document."
  def status(fleet \\ fleet()) do
    %{
      schema: "nerves_gate.status.v3",
      local: public_snapshot(fleet.local),
      replicas:
        Map.new(fleet.replicas, fn {id, replica} ->
          {id,
           public_term(%{
             boot_id: replica.boot_id,
             revision: replica.revision,
             connected: replica.connected,
             last_seen_at: replica.last_seen_at,
             state: replica.state
           })}
        end)
    }
  end

  defp public_snapshot(snapshot) do
    public_term(%{
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      hydrated: snapshot.hydrated,
      state: snapshot.state
    })
  end

  defp public_term(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp public_term(%_{} = struct), do: struct |> Map.from_struct() |> public_term()

  defp public_term(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, public_term(item)} end)
  end

  defp public_term(value) when is_list(value), do: Enum.map(value, &public_term/1)
  defp public_term({a, b, c, d}), do: {a, b, c, d} |> :inet.ntoa() |> List.to_string()
  defp public_term(value), do: value
end

defmodule NervesGate.Cluster do
  @moduledoc """
  Owns distributed Erlang and coordinates independently supervised peer FSMs.

  Cluster coordination is a desired-state reconciler. Peer connection protocols
  remain Finitomata machines because discovery, foreign-group classification,
  connection, and backoff have meaningful ordered transitions.
  """

  use GenServer

  alias NervesGate.Cluster.{Discovery, Distribution, Status}
  alias NervesGate.Cluster.Peer.Supervisor, as: PeerSupervisor
  alias NervesGate.Gateway.{Configuration, Settings}
  alias NervesGate.Retry

  @group_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @retry_delay 30_000
  @tick_interval 1_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(
      __MODULE__,
      Keyword.get_lazy(options, :payload, &new/0),
      name: Keyword.get(options, :name, __MODULE__)
    )
  end

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    %{
      phase: :disabled,
      desired: %{group: Keyword.get(options, :group)},
      observed: %{runtime_ip: nil, node: nil, candidates: []},
      tailnet: Keyword.get(options, :tailnet, &NervesGate.Tailnet.status/0),
      ops: Keyword.get(options, :ops, default_ops()),
      peers: Keyword.get(options, :peers, PeerSupervisor),
      publisher: Keyword.get(options, :publisher, &publish/1),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      last_error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil
    }
  end

  @spec configure(String.t() | nil, GenServer.server()) :: :ok | {:error, term()}
  def configure(group, server \\ __MODULE__) do
    with {:ok, group} <- validate_group(group) do
      GenServer.call(server, {:configure, group}, 35_000)
    end
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec reconcile(GenServer.server()) :: :ok | {:error, term()}
  def reconcile(server \\ __MODULE__) do
    GenServer.call(server, :reconcile, 35_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec heal(GenServer.server()) :: :ok | {:error, term()}
  def heal(server \\ __MODULE__) do
    GenServer.call(server, :heal, 35_000)
  catch
    :exit, _reason -> {:error, :owner_unavailable}
  end

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__), do: call_or(server, :status, disabled_status())

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__), do: call_or(server, :diagnostics, nil)

  @spec validate_group(term()) :: {:ok, String.t() | nil} | {:error, :invalid_cluster_group}
  def validate_group(value) when value in [nil, ""], do: {:ok, nil}

  def validate_group(value) when is_binary(value) and byte_size(value) in 1..128 do
    value = String.trim(value)

    if byte_size(value) in 1..128 and String.match?(value, @group_pattern),
      do: {:ok, value},
      else: {:error, :invalid_cluster_group}
  end

  def validate_group(_value), do: {:error, :invalid_cluster_group}

  @impl true
  def init(state) do
    state = restore_desired_group(state)
    schedule_tick()
    publish_state(state)
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_call({:configure, group}, _from, state) do
    state = put_in(state, [:desired, :group], group) |> reconcile_state(force: true)
    publish_state(state)
    {:reply, :ok, state}
  end

  def handle_call(:reconcile, _from, state) do
    state = reconcile_state(state)
    publish_state(state)
    {:reply, :ok, state}
  end

  def handle_call(:heal, _from, state) do
    state = reconcile_state(state, force: true)
    publish_state(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}
  def handle_call(:diagnostics, _from, state), do: {:reply, diagnostic_view(state), state}
  def handle_call(:state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:tick, _payload}, state) do
    state = reconcile_state(state)
    publish_state(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    state = reconcile_state(state)
    publish_state(state)
    {:noreply, state}
  end

  def handle_info(:tick, state) do
    schedule_tick()
    state = reconcile_state(state)
    publish_state(state)
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    stop_runtime(state)
    :ok
  end

  defp reconcile_state(state, options \\ []) do
    force = Keyword.get(options, :force, false)
    tailnet = safe_tailnet(state)

    cond do
      is_nil(state.desired.group) ->
        state |> stop_runtime() |> sync_peers() |> stable(:disabled)

      not match?(%{online: true, ipv4: ipv4} when is_binary(ipv4), tailnet) ->
        state
        |> stop_runtime()
        |> sync_peers()
        |> Map.merge(%{phase: :blocked, blocked_by: :tailnet})

      state.phase == :backoff and not force and not Retry.due?(state.retry_at) ->
        sync_peers(state)

      state.phase == :online and runtime_matches?(state, tailnet.ipv4) ->
        state |> sync_peers() |> stable(:online)

      true ->
        state |> stop_runtime() |> start_runtime(tailnet.ipv4)
    end
  catch
    _kind, reason ->
      enter_backoff(state, {:cluster_reconciliation_crashed, Retry.public_error(reason)})
  end

  defp start_runtime(state, ipv4) do
    cookie = String.to_atom(state.desired.group)

    case state.ops.start.(ipv4, cookie) do
      {:ok, node_name} when is_atom(node_name) ->
        state
        |> put_in([:observed, :runtime_ip], ipv4)
        |> put_in([:observed, :node], node_name)
        |> sync_peers()
        |> stable(:online)

      {:error, reason} ->
        enter_backoff(state, {:distribution_start_failed, Retry.public_error(reason)})

      invalid ->
        enter_backoff(state, {:invalid_distribution_start_result, Retry.public_error(invalid)})
    end
  end

  defp runtime_matches?(state, ipv4) do
    state.observed.runtime_ip == ipv4 and state.ops.alive?.()
  end

  defp stop_runtime(state) do
    if state.observed.node || state.ops.alive?.(), do: state.ops.stop.()
    %{state | observed: %{state.observed | runtime_ip: nil, node: nil}}
  end

  defp sync_peers(state) do
    candidates = peer_candidates(safe_tailnet(state), state.observed.runtime_ip)
    sync_peer_machines(state.peers, candidates, state.desired.group, peer_ops(state.ops))
    put_in(state, [:observed, :candidates], candidates)
  catch
    :exit, _reason -> state
  end

  defp peer_candidates(%{nodes: nodes}, local_ipv4) do
    nodes
    |> Enum.filter(fn candidate ->
      Map.get(candidate, :self, false) == false and Map.get(candidate, :online, false) and
        is_binary(Map.get(candidate, :ipv4)) and Map.get(candidate, :ipv4) != local_ipv4 and
        gateway_hostname?(Map.get(candidate, :hostname))
    end)
    |> Enum.map(fn candidate ->
      ipv4 = Map.fetch!(candidate, :ipv4)
      %{hostname: Map.get(candidate, :hostname), ipv4: ipv4, node: "nervesgate@#{ipv4}"}
    end)
    |> Enum.uniq_by(& &1.ipv4)
    |> Enum.sort_by(&{&1.hostname || "", &1.ipv4})
  end

  defp peer_candidates(_tailnet, _local_ipv4), do: []
  defp gateway_hostname?("nervesgate-" <> _rest), do: true
  defp gateway_hostname?(_hostname), do: false

  defp stable(state, phase) do
    %{
      state
      | phase: phase,
        last_error: nil,
        blocked_by: nil,
        attempt: 0,
        retry_at: nil
    }
  end

  defp enter_backoff(state, error) do
    %{
      state
      | phase: :backoff,
        last_error: error,
        blocked_by: nil,
        attempt: state.attempt + 1,
        retry_at: Retry.now() + state.retry_delay
    }
  end

  defp public_status(state) do
    candidates = state |> peers() |> Enum.map(&Map.drop(&1, [:state]))
    online = state.phase == :online and state.ops.alive?.()
    connected = if online, do: state.ops.connected.() |> Enum.sort(), else: []
    group = state.desired.group

    %Status{
      state: state.phase,
      enabled: not is_nil(group),
      group: group,
      online: online,
      node: if(online, do: state.observed.node),
      connected: connected,
      candidates: candidates,
      groups: available_groups(group, candidates)
    }
  end

  defp diagnostic_view(state) do
    %{
      state: state.phase,
      desired: state.desired,
      observed: state.observed,
      blocked_by: state.blocked_by,
      last_error: state.last_error,
      attempt: state.attempt,
      retry_at: state.retry_at,
      peers: peers(state)
    }
  end

  defp peers(%{peers: peers}) when is_map(peers), do: peers.statuses.()

  defp peers(state) do
    state.peers.statuses()
  catch
    _kind, _reason -> []
  end

  defp restore_desired_group(%{desired: %{group: nil}} = state) do
    case GenServer.whereis(Configuration) do
      pid when is_pid(pid) ->
        put_in(state, [:desired, :group], Configuration.current() |> Settings.cluster_group())

      nil ->
        state
    end
  catch
    _kind, _reason -> state
  end

  defp restore_desired_group(state), do: state

  defp sync_peer_machines(peers, candidates, group, ops) when is_map(peers),
    do: peers.sync.(candidates, group, ops)

  defp sync_peer_machines(peers, candidates, group, ops),
    do: peers.sync(candidates, group, ops)

  defp available_groups(local_group, candidates) do
    members =
      if(local_group, do: [%{group: local_group, connected: true, self: true}], else: []) ++
        for(
          %{discovered: true, group: group} = candidate <- candidates,
          is_binary(group),
          do: %{group: group, connected: candidate.connected, self: false}
        )

    members
    |> Enum.group_by(& &1.group)
    |> Enum.map(fn {name, group_members} ->
      %{
        name: name,
        members: length(group_members),
        connected: Enum.count(group_members, & &1.connected),
        active: name == local_group
      }
    end)
    |> Enum.sort_by(& &1.name)
  end

  defp disabled_status do
    %Status{
      state: :disabled,
      enabled: false,
      group: nil,
      online: false,
      node: nil,
      connected: [],
      candidates: [],
      groups: []
    }
  end

  defp call_or(server, message, fallback) do
    GenServer.call(server, message)
  catch
    :exit, _reason -> fallback
  end

  defp safe_tailnet(state), do: state.tailnet.()
  defp peer_ops(ops), do: Map.take(ops, [:discover, :connect, :connected])
  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
  defp publish_state(state), do: state.publisher.(public_status(state))

  defp default_ops do
    %{
      start: &Distribution.start/2,
      stop: &Distribution.stop/0,
      alive?: &Distribution.alive?/0,
      connect: &Distribution.connect/1,
      connected: &Distribution.connected/0,
      discover: &Discovery.fetch/1
    }
  end

  defp publish(status) do
    public = %{
      status
      | node: encode_node(status.node),
        connected: Enum.map(status.connected, &encode_node/1)
    }

    case NervesGate.DeviceState.publish({:state_reported, :cluster, public}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "Cluster DeviceState publication failed: #{inspect(reason)}"
    end
  end

  defp encode_node(nil), do: nil
  defp encode_node(node), do: to_string(node)
end

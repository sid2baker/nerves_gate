defmodule NervesGate.Cluster do
  @moduledoc """
  Owns the single distributed-Erlang runtime and all peer reconciliation.

  Tailnet observations determine the local distribution address and candidate
  gateways. One bounded owner-monitored effect concurrently discovers and
  connects candidates. Immutable peer results retain public and diagnostic
  evidence; no process, registry, supervisor, or timer is allocated per peer.
  """

  use GenServer

  alias NervesGate.Cluster.{Distribution, Group, Status}
  alias NervesGate.FSM.Effect
  alias NervesGate.Reconciliation

  @retry_delay 30_000
  @tick_interval 1_000
  @peer_timeout 5_000
  @max_peer_concurrency 4

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options) do
    GenServer.start_link(
      __MODULE__,
      Keyword.get_lazy(options, :payload, fn -> new(options) end),
      name: Keyword.get(options, :name, __MODULE__)
    )
  end

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    %{
      phase: :disabled,
      desired: %{group: Keyword.get(options, :group)},
      observed: %{runtime_ip: nil, runtime_group: nil, node: nil, candidates: []},
      peers: %{},
      peer_signature: nil,
      peer_effect: nil,
      peer_retry_at: nil,
      tailnet: Keyword.get(options, :tailnet, &NervesGate.Tailnet.status/0),
      ops: Keyword.get(options, :ops, default_ops()),
      publisher: Keyword.get(options, :publisher, &publish/1),
      load_group: Keyword.get(options, :load_group, fn -> nil end),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      peer_timeout: Keyword.get(options, :peer_timeout, @peer_timeout),
      max_peer_concurrency: Keyword.get(options, :max_peer_concurrency, @max_peer_concurrency),
      last_error: nil,
      blocked_by: nil,
      attempt: 0,
      retry_at: nil
    }
  end

  @spec configure(String.t() | nil, GenServer.server()) :: :ok | {:error, term()}
  def configure(group, server \\ __MODULE__) do
    with {:ok, group} <- Group.validate(group) do
      GenServer.call(server, {:configure, group})
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
    changed? = state.desired.group != group
    state = put_in(state, [:desired, :group], group)

    state =
      if changed? do
        phase = if is_nil(group), do: :disabled, else: :blocked
        Map.merge(state, %{phase: phase, blocked_by: :configuration, retry_at: nil})
      else
        state
      end

    publish_state(state)
    send(self(), :reconcile)
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
  def handle_cast(
        {:peer_scan_completed, {ref, outcome}},
        %{peer_effect: %{ref: ref}} = state
      ) do
    state = complete_peer_scan(%{state | peer_effect: nil}, outcome)
    publish_state(state)
    {:noreply, state}
  end

  def handle_cast({:peer_scan_completed, _stale}, state), do: {:noreply, state}

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
    state |> clear_peers() |> stop_runtime()
    :ok
  end

  defp reconcile_state(state, options \\ []) do
    force = Keyword.get(options, :force, false)
    tailnet = state.tailnet.()

    cond do
      is_nil(state.desired.group) ->
        state |> clear_peers() |> stop_runtime() |> stable(:disabled)

      not match?(%{online: true, ipv4: ipv4} when is_binary(ipv4), tailnet) ->
        state
        |> clear_peers()
        |> stop_runtime()
        |> Map.merge(%{phase: :blocked, blocked_by: :tailnet})

      state.phase == :backoff and not force and not Reconciliation.due?(state.retry_at) ->
        clear_peers(state)

      state.phase == :online and runtime_matches?(state, tailnet.ipv4) ->
        state |> sync_peers(tailnet) |> stable(:online)

      true ->
        state |> clear_peers() |> stop_runtime() |> start_runtime(tailnet)
    end
  catch
    _kind, reason ->
      state
      |> clear_peers()
      |> enter_backoff({:cluster_reconciliation_crashed, Reconciliation.public_error(reason)})
  end

  defp start_runtime(state, tailnet) do
    cookie = String.to_atom(state.desired.group)

    case state.ops.start.(tailnet.ipv4, cookie) do
      {:ok, node_name} when is_atom(node_name) ->
        state
        |> put_in([:observed, :runtime_ip], tailnet.ipv4)
        |> put_in([:observed, :runtime_group], state.desired.group)
        |> put_in([:observed, :node], node_name)
        |> sync_peers(tailnet)
        |> stable(:online)

      {:error, reason} ->
        enter_backoff(state, {:distribution_start_failed, Reconciliation.public_error(reason)})

      invalid ->
        enter_backoff(
          state,
          {:invalid_distribution_start_result, Reconciliation.public_error(invalid)}
        )
    end
  end

  defp runtime_matches?(state, ipv4) do
    state.observed.runtime_ip == ipv4 and
      state.observed.runtime_group == state.desired.group and state.ops.alive?.()
  end

  defp stop_runtime(state) do
    if state.observed.node || state.ops.alive?.(), do: state.ops.stop.()

    %{
      state
      | observed: %{
          state.observed
          | runtime_ip: nil,
            runtime_group: nil,
            node: nil,
            candidates: []
        }
    }
  end

  defp sync_peers(state, tailnet) do
    candidates = peer_candidates(tailnet, state.observed.runtime_ip)
    signature = {state.desired.group, candidates}

    state
    |> install_candidates(candidates, signature)
    |> refresh_peer_connections()
    |> maybe_start_peer_scan()
  end

  defp install_candidates(%{peer_signature: signature} = state, candidates, signature) do
    put_in(state, [:observed, :candidates], candidates)
  end

  defp install_candidates(state, candidates, signature) do
    state = cancel_peer_scan(state)
    connected = connected_names(state)

    peers =
      Map.new(candidates, fn candidate ->
        {candidate.ipv4, pending_peer(candidate, candidate.node in connected)}
      end)

    %{
      state
      | observed: %{state.observed | candidates: candidates},
        peers: peers,
        peer_signature: signature,
        peer_retry_at: nil
    }
  end

  defp refresh_peer_connections(state) do
    connected = connected_names(state)

    {peers, disconnected?} =
      Enum.reduce(state.peers, {%{}, false}, fn {ipv4, peer}, {peers, disconnected?} ->
        connected? = peer.candidate.node in connected
        disconnected? = disconnected? or (peer.connected and not connected?)
        peer = %{peer | connected: connected?, phase: peer_phase(peer, connected?)}
        {Map.put(peers, ipv4, peer), disconnected?}
      end)

    %{state | peers: peers, peer_retry_at: if(disconnected?, do: nil, else: state.peer_retry_at)}
  end

  defp peer_phase(_peer, true), do: :connected
  defp peer_phase(%{phase: :connected}, false), do: :connecting
  defp peer_phase(peer, false), do: peer.phase

  defp maybe_start_peer_scan(%{peer_effect: effect} = state) when not is_nil(effect), do: state
  defp maybe_start_peer_scan(%{peers: peers} = state) when map_size(peers) == 0, do: state

  defp maybe_start_peer_scan(state) do
    if Reconciliation.due?(state.peer_retry_at) do
      start_peer_scan(state)
    else
      state
    end
  end

  defp start_peer_scan(state) do
    ref = make_ref()
    candidates = state.observed.candidates
    group = state.desired.group
    ops = state.ops
    timeout = state.peer_timeout
    concurrency = state.max_peer_concurrency
    effect_timeout = scan_timeout(length(candidates), concurrency, timeout)

    case Effect.start(
           self(),
           ref,
           fn -> scan_peers(candidates, group, ops, concurrency, timeout) end,
           fn ref, outcome -> {:peer_scan_completed, {ref, outcome}} end,
           timeout: effect_timeout
         ) do
      {:ok, coordinator} ->
        %{state | peer_effect: %{ref: ref, coordinator: coordinator}}

      {:error, reason} ->
        error = {:peer_effect_launch_failed, Reconciliation.public_error(reason)}
        fail_peer_scan(state, error)
    end
  end

  defp scan_timeout(count, concurrency, timeout) do
    batches = count |> Kernel.+(concurrency - 1) |> div(concurrency)
    max(timeout + 1_000, batches * timeout + 1_000)
  end

  defp scan_peers(candidates, group, ops, concurrency, timeout) do
    connected = ops.connected.() |> Enum.map(&to_string/1) |> MapSet.new()

    results =
      Task.async_stream(
        candidates,
        &scan_peer(&1, group, connected, ops),
        max_concurrency: concurrency,
        ordered: true,
        on_timeout: :kill_task,
        timeout: timeout
      )

    candidates
    |> Enum.zip(results)
    |> Map.new(fn {candidate, result} -> {candidate.ipv4, scan_result(candidate, result)} end)
  end

  defp scan_peer(candidate, group, connected, ops) do
    case ops.discover.(candidate.ipv4) do
      {:ok, discovered_group} when is_binary(discovered_group) or is_nil(discovered_group) ->
        connect_discovered(candidate, group, discovered_group, connected, ops)

      {:error, reason} ->
        {:error, {:discovery_failed, Reconciliation.public_error(reason)}}

      invalid ->
        {:error, {:invalid_discovery_result, Reconciliation.public_error(invalid)}}
    end
  catch
    _kind, reason -> {:error, {:peer_operation_crashed, Reconciliation.public_error(reason)}}
  end

  defp connect_discovered(candidate, group, discovered_group, connected, ops) do
    cond do
      not is_binary(discovered_group) or discovered_group != group ->
        {:foreign, discovered_group}

      candidate.node in connected ->
        {:connected, discovered_group}

      true ->
        connect_peer(candidate, discovered_group, ops)
    end
  end

  defp connect_peer(candidate, discovered_group, ops) do
    case ops.connect.(candidate.ipv4) do
      {:ok, node_name} ->
        if to_string(node_name) == candidate.node,
          do: {:connected, discovered_group},
          else: {:error, {:connect_failed, :unexpected_node}}

      {:error, reason} ->
        {:error, {:connect_failed, Reconciliation.public_error(reason)}}

      invalid ->
        {:error, {:invalid_connect_result, Reconciliation.public_error(invalid)}}
    end
  end

  defp scan_result(candidate, {:ok, {:connected, group}}),
    do: peer(candidate, :connected, group, true, nil)

  defp scan_result(candidate, {:ok, {:foreign, group}}),
    do: peer(candidate, :foreign, group, false, nil)

  defp scan_result(candidate, {:ok, {:error, reason}}),
    do: peer(candidate, :backoff, nil, false, reason)

  defp scan_result(candidate, {:exit, _reason}),
    do: peer(candidate, :backoff, nil, false, {:peer_operation_failed, :timeout})

  defp complete_peer_scan(state, {:returned, peers}) when is_map(peers) do
    state
    |> Map.put(:peers, peers)
    |> Map.put(:peer_retry_at, Reconciliation.after_ms(state.retry_delay))
    |> refresh_peer_connections()
  end

  defp complete_peer_scan(state, :timed_out),
    do: fail_peer_scan(state, {:peer_scan_failed, :timed_out})

  defp complete_peer_scan(state, :cancelled),
    do: fail_peer_scan(state, {:peer_scan_failed, :cancelled})

  defp complete_peer_scan(state, {:crashed, _kind, reason, _stack}),
    do: fail_peer_scan(state, {:peer_scan_failed, Reconciliation.public_error(reason)})

  defp complete_peer_scan(state, _invalid),
    do: fail_peer_scan(state, {:peer_scan_failed, :invalid_result})

  defp fail_peer_scan(state, error) do
    peers =
      Map.new(state.peers, fn {ipv4, peer} ->
        {ipv4, %{peer | phase: :backoff, connected: false, last_error: error}}
      end)

    state
    |> Map.put(:peers, peers)
    |> Map.put(:peer_retry_at, Reconciliation.after_ms(state.retry_delay))
    |> refresh_peer_connections()
  end

  defp pending_peer(candidate, connected?) do
    peer(candidate, if(connected?, do: :connected, else: :discovering), nil, connected?, nil)
  end

  defp peer(candidate, phase, group, connected, last_error) do
    %{
      candidate: candidate,
      phase: phase,
      discovered_group: group,
      connected: connected,
      last_error: last_error
    }
  end

  defp cancel_peer_scan(%{peer_effect: %{coordinator: coordinator}} = state) do
    Effect.cancel(coordinator)
    %{state | peer_effect: nil}
  end

  defp cancel_peer_scan(state), do: state

  defp clear_peers(state) do
    state = cancel_peer_scan(state)

    %{
      state
      | peers: %{},
        peer_signature: nil,
        peer_retry_at: nil,
        observed: %{state.observed | candidates: []}
    }
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

  defp connected_names(state) do
    state.ops.connected.() |> Enum.map(&to_string/1) |> MapSet.new()
  catch
    _kind, _reason -> MapSet.new()
  end

  defp stable(state, phase) do
    state
    |> Map.merge(Reconciliation.converged())
    |> Map.merge(%{phase: phase, blocked_by: nil})
  end

  defp enter_backoff(state, error) do
    state
    |> Map.merge(Reconciliation.failed(state.attempt, state.retry_delay, error))
    |> Map.merge(%{phase: :backoff, blocked_by: nil})
  end

  defp public_status(state) do
    candidates = public_peers(state.peers)
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

  defp public_peers(peers) do
    peers
    |> Map.values()
    |> Enum.map(fn peer ->
      Map.merge(peer.candidate, %{
        group: peer.discovered_group,
        discovered: is_binary(peer.discovered_group),
        connected: peer.connected,
        last_error: public_peer_error(peer.last_error)
      })
    end)
    |> Enum.sort_by(&{&1.hostname || "", &1.ipv4})
  end

  defp public_peer_error(nil), do: nil

  defp public_peer_error({kind, reason}) when is_atom(kind) and is_atom(reason),
    do: %{kind: kind, reason: reason}

  defp public_peer_error(reason) when is_atom(reason), do: %{kind: reason}
  defp public_peer_error(_reason), do: %{kind: :operation_failed}

  defp diagnostic_view(state) do
    %{
      state: state.phase,
      desired: state.desired,
      observed: state.observed,
      blocked_by: state.blocked_by,
      last_error: state.last_error,
      attempt: state.attempt,
      retry_at: state.retry_at,
      peers: diagnostic_peers(state)
    }
  end

  defp diagnostic_peers(state) do
    Map.new(state.peers, fn {ipv4, peer} ->
      {ipv4,
       %{
         state: peer.phase,
         desired: %{group: state.desired.group},
         observed: Map.put(peer.candidate, :group, peer.discovered_group),
         blocked_by: nil,
         last_error: peer.last_error,
         attempt: if(peer.last_error, do: 1, else: 0),
         retry_at: state.peer_retry_at,
         effect: state.peer_effect
       }}
    end)
  end

  defp restore_desired_group(%{desired: %{group: nil}} = state) do
    with group <- state.load_group.(),
         {:ok, group} <- Group.validate(group) do
      put_in(state, [:desired, :group], group)
    else
      _unavailable -> state
    end
  catch
    _kind, _reason -> state
  end

  defp restore_desired_group(state), do: state

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

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_interval)
  defp publish_state(state), do: state.publisher.(public_status(state))

  defp default_ops do
    %{
      start: &Distribution.start/2,
      stop: &Distribution.stop/0,
      alive?: &Distribution.alive?/0,
      connect: &Distribution.connect/1,
      connected: &Distribution.connected/0,
      discover: &discover_group/1
    }
  end

  defp discover_group(ipv4) do
    url = ~c"http://#{ipv4}/api/discovery"
    http_options = [timeout: 2_000, connect_timeout: 2_000]

    with {:ok, {{_version, 200, _reason}, _headers, body}} <-
           :httpc.request(:get, {url, []}, http_options, body_format: :binary),
         {:ok, %{"cluster_group" => group}} <- Jason.decode(body),
         {:ok, group} <- Group.validate(group) do
      {:ok, group}
    else
      {:ok, {{_version, status, _reason}, _headers, _body}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}

      _invalid ->
        {:error, :invalid_discovery_response}
    end
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

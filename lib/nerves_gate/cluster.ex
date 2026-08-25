defmodule NervesGate.Cluster.Status do
  @moduledoc "Secret-free public cluster state."

  @enforce_keys [:state, :enabled, :group, :online, :node, :connected, :candidates, :groups]
  defstruct [:state, :enabled, :group, :online, :node, :connected, :candidates, :groups]

  @type t :: %__MODULE__{
          state: :disabled | :reconciling | :blocked | :online | :backoff,
          enabled: boolean(),
          group: String.t() | nil,
          online: boolean(),
          node: node() | nil,
          connected: [node()],
          candidates: [map()],
          groups: [map()]
        }
end

defmodule NervesGate.Cluster do
  @moduledoc "Lifecycle owner for distributed Erlang and independently supervised gateway peers."

  alias NervesGate.Cluster.Discovery
  alias NervesGate.Cluster.Distribution
  alias NervesGate.Cluster.Peer.Supervisor, as: PeerSupervisor
  alias NervesGate.Cluster.Status
  alias NervesGate.FSM.Diagnostics
  alias NervesGate.FSM.Retry

  @group_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9_-]*\z/
  @retry_delay 30_000

  @fsm """
  [*] --> disabled : boot
  disabled --> disabled : configure
  disabled --> blocked : configure
  disabled --> reconciling : configure
  disabled --> disabled : tick
  disabled --> reconciling : tick
  disabled --> disabled : heal
  blocked --> disabled : configure
  blocked --> blocked : configure
  blocked --> reconciling : configure
  blocked --> blocked : tick
  blocked --> reconciling : tick
  blocked --> blocked : heal
  blocked --> reconciling : heal
  online --> disabled : configure
  online --> blocked : configure
  online --> reconciling : configure
  online --> online : tick
  online --> blocked : tick
  online --> reconciling : tick
  online --> online : heal
  online --> blocked : heal
  online --> reconciling : heal
  backoff --> disabled : configure
  backoff --> blocked : configure
  backoff --> reconciling : configure
  backoff --> backoff : tick
  backoff --> blocked : tick
  backoff --> reconciling : tick
  backoff --> blocked : heal
  backoff --> reconciling : heal
  reconciling --> disabled : reconciliation_completed
  reconciling --> online : reconciliation_completed
  reconciling --> blocked : reconciliation_completed
  reconciling --> backoff : reconciliation_completed
  reconciling --> reconciling : tick
  disabled --> [*] : terminate
  blocked --> [*] : terminate
  online --> [*] : terminate
  backoff --> [*] : terminate
  reconciling --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 1_000

  @spec new(keyword()) :: map()
  def new(options \\ []) do
    Diagnostics.new(%{
      owner: __MODULE__,
      desired: %{group: Keyword.get(options, :group)},
      observed: %{runtime_ip: nil, node: nil},
      tailnet: Keyword.get(options, :tailnet, &NervesGate.Tailnet.status/0),
      ops: Keyword.get(options, :ops, default_ops()),
      peers: Keyword.get(options, :peers, PeerSupervisor),
      publisher: Keyword.get(options, :publisher, &publish/1),
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay),
      effect_timeout: Keyword.get(options, :effect_timeout, 30_000),
      effect: nil,
      last_result: nil
    })
  end

  @spec configure(String.t() | nil, GenServer.server()) :: :ok | {:error, term()}
  def configure(group, server \\ __MODULE__) do
    with {:ok, group} <- validate_group(group) do
      Diagnostics.command(server, :configure, %{group: group}, 35_000)
    end
  end

  @spec reconcile(GenServer.server()) :: :ok | {:error, term()}
  def reconcile(server \\ __MODULE__), do: Diagnostics.command(server, :tick, %{}, 35_000)

  @spec heal(GenServer.server()) :: :ok | {:error, term()}
  def heal(server \\ __MODULE__), do: Diagnostics.command(server, :heal, %{}, 35_000)

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: state, payload: payload} -> public_status(state, payload)
      nil -> disabled_status()
    end
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__) do
    case Diagnostics.state(server) do
      %Finitomata.State{} = state ->
        Diagnostics.view(state) |> Map.put(:peers, peers(state.payload))

      nil ->
        nil
    end
  end

  @spec validate_group(term()) :: {:ok, String.t() | nil} | {:error, :invalid_cluster_group}
  def validate_group(value) when value in [nil, ""], do: {:ok, nil}

  def validate_group(value) when is_binary(value) and byte_size(value) in 1..128 do
    value = String.trim(value)

    if byte_size(value) in 1..128 and String.match?(value, @group_pattern),
      do: {:ok, value},
      else: {:error, :invalid_cluster_group}
  end

  def validate_group(_value), do: {:error, :invalid_cluster_group}

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload),
    do: finish(:*, :boot, :disabled, payload)

  def on_transition(state, :configure, command, payload) do
    payload = put_in(payload, [:desired, :group], command.group)
    begin_reconciliation(state, :configure, command, payload)
  end

  def on_transition(:disabled, :heal, command, payload),
    do: finish(:disabled, :heal, :disabled, result(payload, command_id(command), :ok))

  def on_transition(:reconciling, :tick, _event_payload, payload),
    do: finish(:reconciling, :tick, :reconciling, payload)

  def on_transition(state, event, command, payload) when event in [:tick, :heal],
    do: begin_reconciliation(state, event, command, payload)

  def on_transition(
        :reconciling,
        :reconciliation_completed,
        {ref, outcome},
        %{effect: %{ref: ref, command_id: command_id}} = payload
      ) do
    payload = %{payload | effect: nil}
    complete_reconciliation(outcome, command_id, payload)
  end

  def on_transition(:reconciling, :reconciliation_completed, _stale, _payload),
    do: {:error, :stale_effect_completion}

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :tick, payload}

  @impl Finitomata
  def on_terminate(%Finitomata.State{payload: payload}) do
    stop_runtime(payload)
    :ok
  end

  defp begin_reconciliation(from, event, command, payload) do
    effect = %{
      ref: make_ref(),
      from: from,
      event: event,
      command_id: command_id(command)
    }

    finish(from, event, :reconciling, %{payload | effect: effect}, blocked_by: nil)
  end

  defp reconcile_runtime(payload, from, event) do
    tailnet = safe_tailnet(payload)

    cond do
      is_nil(payload.desired.group) ->
        payload = payload |> stop_runtime() |> sync_peers()
        finish(from, event, :disabled, payload, error: nil, blocked_by: nil, attempt: 0)

      not match?(%{online: true, ipv4: ipv4} when is_binary(ipv4), tailnet) ->
        payload = payload |> stop_runtime() |> sync_peers()
        finish(from, event, :blocked, payload, blocked_by: :tailnet)

      from == :backoff and event == :tick and not Retry.due?(payload.retry_at) ->
        finish(from, event, :backoff, sync_peers(payload))

      from == :online and runtime_matches?(payload, tailnet.ipv4) ->
        finish(from, event, :online, sync_peers(payload), error: nil)

      true ->
        payload
        |> stop_runtime()
        |> start_runtime(tailnet.ipv4, from, event)
    end
  end

  defp start_runtime(payload, ipv4, from, event) do
    cookie = String.to_atom(payload.desired.group)

    case payload.ops.start.(ipv4, cookie) do
      {:ok, node_name} when is_atom(node_name) ->
        payload =
          payload
          |> put_in([:observed, :runtime_ip], ipv4)
          |> put_in([:observed, :node], node_name)
          |> sync_peers()

        finish(from, event, :online, payload,
          error: nil,
          blocked_by: nil,
          attempt: 0,
          retry_at: nil
        )

      {:error, reason} ->
        backoff(payload, from, event, {:distribution_start_failed, Retry.public_error(reason)})

      invalid ->
        backoff(
          payload,
          from,
          event,
          {:invalid_distribution_start_result, Retry.public_error(invalid)}
        )
    end
  end

  defp backoff(payload, from, event, error) do
    attempt = payload.attempt + 1

    finish(from, event, :backoff, payload,
      reason: error,
      error: error,
      attempt: attempt,
      retry_at: Retry.now() + payload.retry_delay
    )
  end

  defp complete_reconciliation({:returned, {:ok, to, completed}}, command_id, _payload) do
    completed = completed |> Map.put(:effect, nil) |> result(command_id, :ok)
    finish(:reconciling, :reconciliation_completed, to, completed)
  end

  defp complete_reconciliation(:timed_out, command_id, payload),
    do: effect_failed(payload, command_id, :cluster_reconciliation_timed_out)

  defp complete_reconciliation(:cancelled, command_id, payload),
    do: effect_failed(payload, command_id, :cluster_reconciliation_cancelled)

  defp complete_reconciliation({:crashed, _kind, reason, _stack}, command_id, payload),
    do:
      effect_failed(
        payload,
        command_id,
        {:cluster_reconciliation_crashed, Retry.public_error(reason)}
      )

  defp complete_reconciliation(_invalid, command_id, payload),
    do: effect_failed(payload, command_id, :invalid_cluster_reconciliation_result)

  defp effect_failed(payload, command_id, error) do
    attempt = payload.attempt + 1
    payload = result(payload, command_id, {:error, error})

    finish(:reconciling, :reconciliation_completed, :backoff, payload,
      reason: error,
      error: error,
      attempt: attempt,
      retry_at: Retry.now() + payload.retry_delay
    )
  end

  defp runtime_matches?(payload, ipv4) do
    payload.observed.runtime_ip == ipv4 and payload.ops.alive?.()
  end

  defp stop_runtime(payload) do
    if payload.observed.node || payload.ops.alive?.(), do: payload.ops.stop.()
    %{payload | observed: %{runtime_ip: nil, node: nil}}
  end

  defp sync_peers(payload) do
    candidates = peer_candidates(safe_tailnet(payload), payload.observed.runtime_ip)
    sync_peer_machines(payload.peers, candidates, payload.desired.group, peer_ops(payload.ops))
    %{payload | observed: Map.put(payload.observed, :candidates, candidates)}
  catch
    :exit, _reason -> payload
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

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end

  @doc false
  def after_transition(state, payload) do
    payload.publisher.(public_status(state, payload))
    launch_reconciliation(state, payload)
  end

  defp launch_reconciliation(
         :reconciling,
         %{effect: %{ref: ref, from: from, event: event}} = payload
       ) do
    case NervesGate.FSM.Effect.start(
           self(),
           ref,
           fn -> reconcile_runtime(payload, from, event) end,
           fn ref, outcome -> {:reconciliation_completed, {ref, outcome}} end,
           timeout: payload.effect_timeout
         ) do
      {:ok, _coordinator} -> :ok
      {:error, reason} -> raise "Cluster effect launch failed: #{inspect(reason)}"
    end
  end

  defp launch_reconciliation(_state, _payload), do: :ok

  defp command_id(%{id: id}), do: id
  defp command_id(_timer), do: nil
  defp result(payload, nil, _value), do: payload
  defp result(payload, id, value), do: %{payload | last_result: {id, value}}

  defp public_status(state, payload) do
    public_state = public_state(state, payload)
    candidates = payload |> peers() |> Enum.map(&Map.drop(&1, [:state]))
    online = public_state == :online and payload.ops.alive?.()
    connected = if online, do: payload.ops.connected.() |> Enum.sort(), else: []
    group = payload.desired.group

    %Status{
      state: public_state,
      enabled: not is_nil(group),
      group: group,
      online: online,
      node: if(online, do: payload.observed.node),
      connected: Enum.sort(connected),
      candidates: candidates,
      groups: available_groups(group, candidates)
    }
  end

  # A periodic check is an internal lifecycle phase, not evidence that a live
  # distribution runtime went offline. Commands remain publicly visible as
  # :reconciling because they can change the configured runtime.
  defp public_state(:reconciling, %{effect: %{from: from, event: event}})
       when event in [:tick, :heal],
       do: from

  defp public_state(state, _payload), do: state

  defp peers(%{peers: peers}) when is_map(peers), do: peers.statuses.()
  defp peers(payload), do: payload.peers.statuses()

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

  defp safe_tailnet(payload), do: payload.tailnet.()

  defp peer_ops(ops), do: Map.take(ops, [:discover, :connect, :connected])

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

defmodule NervesGate.Cluster.Supervisor do
  @moduledoc "Supervises the cluster contract and independent peer machines."

  use Supervisor

  alias NervesGate.Cluster
  alias NervesGate.Cluster.Peer.Supervisor, as: PeerSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    children = [
      PeerSupervisor,
      {Cluster, payload: Cluster.new(options), name: Cluster}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule NervesGate.Cluster.Discovery do
  @moduledoc "Fetches public cluster-group metadata from visible Tailnet gateways."

  @timeout 2_000

  @spec fetch(String.t(), keyword()) :: {:ok, String.t() | nil} | {:error, term()}
  def fetch(ipv4, options \\ []) when is_binary(ipv4) do
    timeout = Keyword.get(options, :timeout, @timeout)
    url = ~c"http://#{ipv4}/api/discovery"
    http_options = [timeout: timeout, connect_timeout: timeout]

    with {:ok, {{_version, 200, _reason}, _headers, body}} <-
           :httpc.request(:get, {url, []}, http_options, body_format: :binary),
         {:ok, %{"cluster_group" => group}} <- Jason.decode(body),
         {:ok, group} <- NervesGate.Cluster.validate_group(group) do
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
end

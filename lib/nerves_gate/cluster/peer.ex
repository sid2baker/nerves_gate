defmodule NervesGate.Cluster.Peer do
  @moduledoc "Independent discovery, connection, retry, and diagnosis for one gateway peer."

  alias NervesGate.FSM.Diagnostics
  alias NervesGate.FSM.Retry

  @fsm """
  [*] --> discovering : boot
  discovering --> discovering : tick
  discovering --> foreign : tick
  discovering --> connecting : tick
  discovering --> backoff : tick
  discovering --> discovering : update
  foreign --> foreign : tick
  foreign --> discovering : tick
  foreign --> foreign : update
  foreign --> discovering : update
  connecting --> connecting : tick
  connecting --> connected : tick
  connecting --> backoff : tick
  connecting --> connecting : update
  connecting --> discovering : update
  connected --> connected : tick
  connected --> connecting : tick
  connected --> connected : update
  connected --> discovering : update
  backoff --> backoff : tick
  backoff --> discovering : tick
  backoff --> backoff : update
  backoff --> discovering : update
  foreign --> [*] : terminate
  """

  use NervesGate.FSM, fsm: @fsm, timer: 1_000

  @retry_delay 30_000

  @spec new(map(), String.t(), map(), keyword()) :: map()
  def new(candidate, group, ops, options \\ []) do
    Diagnostics.new(%{
      desired: %{group: group},
      observed: candidate,
      candidate: candidate,
      discovered_group: nil,
      ops: ops,
      retry_delay: Keyword.get(options, :retry_delay, @retry_delay)
    })
  end

  @spec update(GenServer.server(), map(), String.t()) :: :ok | {:error, term()}
  def update(server, candidate, group) do
    case Diagnostics.transition(server, :update, %{candidate: candidate, group: group}) do
      {:ok, _state} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @spec status(GenServer.server()) :: map() | nil
  def status(server) do
    case Diagnostics.state(server) do
      %Finitomata.State{current: state, payload: payload} ->
        payload.candidate
        |> Map.merge(%{
          state: state,
          group: payload.discovered_group,
          discovered: is_binary(payload.discovered_group),
          connected: state == :connected,
          last_error: public_last_error(payload.last_error)
        })

      nil ->
        nil
    end
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server), do: server |> Diagnostics.state() |> Diagnostics.view()

  @impl Finitomata
  def on_transition(:*, :boot, _event_payload, payload),
    do: finish(:*, :boot, :discovering, payload)

  def on_transition(state, :update, update, payload) do
    changed? = payload.candidate != update.candidate or payload.desired.group != update.group

    payload = %{
      payload
      | candidate: update.candidate,
        desired: %{group: update.group},
        observed: update.candidate
    }

    if changed?,
      do: finish(state, :update, :discovering, payload, retry_at: nil),
      else: finish(state, :update, state, payload)
  end

  def on_transition(:discovering, :tick, _event_payload, payload) do
    case payload.ops.discover.(payload.candidate.ipv4) do
      {:ok, group} when is_binary(group) or is_nil(group) ->
        payload = %{payload | discovered_group: group, last_error: nil}

        if is_binary(group) and group == payload.desired.group do
          finish(:discovering, :tick, :connecting, payload, attempt: 0, retry_at: nil)
        else
          finish(:discovering, :tick, :foreign, payload,
            attempt: 0,
            retry_at: Retry.now() + payload.retry_delay
          )
        end

      {:error, reason} ->
        backoff(:discovering, :tick, payload, {:discovery_failed, Retry.public_error(reason)})

      invalid ->
        backoff(
          :discovering,
          :tick,
          payload,
          {:invalid_discovery_result, Retry.public_error(invalid)}
        )
    end
  end

  def on_transition(:foreign, :tick, _event_payload, payload) do
    if Retry.due?(payload.retry_at),
      do: finish(:foreign, :tick, :discovering, payload),
      else: finish(:foreign, :tick, :foreign, payload)
  end

  def on_transition(:connecting, :tick, _event_payload, payload) do
    node_name = payload.candidate.node

    if connected?(payload, node_name),
      do: connected(payload),
      else: connect(payload, node_name)
  end

  def on_transition(:connected, :tick, _event_payload, payload) do
    if connected?(payload, payload.candidate.node),
      do: finish(:connected, :tick, :connected, payload),
      else: finish(:connected, :tick, :connecting, payload, reason: :nodedown)
  end

  def on_transition(:backoff, :tick, _event_payload, payload) do
    if Retry.due?(payload.retry_at),
      do: finish(:backoff, :tick, :discovering, payload),
      else: finish(:backoff, :tick, :backoff, payload)
  end

  @impl Finitomata
  def on_timer(_state, %Finitomata.State{payload: payload}),
    do: {:transition, :tick, payload}

  defp connect(payload, node_name) do
    case payload.ops.connect.(payload.candidate.ipv4) do
      {:ok, _node} ->
        connected_after_attempt(payload, node_name)

      {:error, reason} ->
        backoff(:connecting, :tick, payload, {:connect_failed, Retry.public_error(reason)})

      invalid ->
        backoff(
          :connecting,
          :tick,
          payload,
          {:invalid_connect_result, Retry.public_error(invalid)}
        )
    end
  end

  defp connected_after_attempt(payload, node_name) do
    if connected?(payload, node_name),
      do: connected(payload),
      else: backoff(:connecting, :tick, payload, :connection_not_established)
  end

  defp connected(payload) do
    finish(:connecting, :tick, :connected, payload,
      error: nil,
      attempt: 0,
      retry_at: nil
    )
  end

  defp backoff(from, event, payload, error) do
    attempt = payload.attempt + 1

    finish(from, event, :backoff, payload,
      reason: error,
      error: error,
      attempt: attempt,
      retry_at: Retry.now() + payload.retry_delay
    )
  end

  defp connected?(payload, expected) do
    payload.ops.connected.()
    |> Enum.map(&to_string/1)
    |> Enum.member?(expected)
  end

  defp public_last_error(nil), do: nil

  defp public_last_error({kind, reason}) when is_atom(kind) and is_atom(reason),
    do: %{kind: kind, reason: reason}

  defp public_last_error(reason) when is_atom(reason), do: %{kind: reason}
  defp public_last_error(_reason), do: %{kind: :operation_failed}

  defp finish(from, event, to, payload, options \\ []) do
    {:ok, to, Diagnostics.record(payload, from, event, to, options)}
  end
end

defmodule NervesGate.Cluster.Peer.Supervisor do
  @moduledoc "Supervises one `Cluster.Peer` lifecycle per current Tailnet gateway peer."

  use Supervisor

  alias NervesGate.Cluster.Peer

  @registry NervesGate.Cluster.Peer.Registry
  @dynamic NervesGate.Cluster.Peer.DynamicSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec sync([map()], String.t(), map()) :: :ok
  def sync(candidates, group, ops) do
    desired = MapSet.new(candidates, & &1.ipv4)

    Enum.each(candidates, fn candidate -> ensure(candidate, group, ops) end)

    Enum.each(entries(), fn {ipv4, pid} ->
      if ipv4 not in desired, do: DynamicSupervisor.terminate_child(@dynamic, pid)
    end)

    :ok
  end

  @spec statuses() :: [map()]
  def statuses do
    entries()
    |> Enum.map(fn {_ipv4, pid} -> Peer.status(pid) end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{&1.hostname || "", &1.ipv4})
  end

  @spec diagnostics() :: %{String.t() => map()}
  def diagnostics do
    Map.new(entries(), fn {ipv4, pid} -> {ipv4, Peer.diagnostics(pid)} end)
  end

  @impl true
  def init(_options) do
    children = [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @dynamic}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp ensure(candidate, group, ops) do
    case Registry.lookup(@registry, candidate.ipv4) do
      [{pid, _value}] ->
        Peer.update(pid, candidate, group)

      [] ->
        name = {:via, Registry, {@registry, candidate.ipv4}}

        child = %{
          id: {Peer, candidate.ipv4},
          start: {Peer, :start_link, [[payload: Peer.new(candidate, group, ops), name: name]]},
          restart: :transient
        }

        case DynamicSupervisor.start_child(@dynamic, child) do
          {:ok, _pid} -> :ok
          {:error, {:already_started, pid}} -> Peer.update(pid, candidate, group)
        end
    end
  end

  defp entries do
    Registry.select(@registry, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
  end
end

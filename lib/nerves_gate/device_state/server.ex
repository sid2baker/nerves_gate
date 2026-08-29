defmodule NervesGate.DeviceState.Server do
  @moduledoc """
  Orders and distributes canonical secret-free public state.

  The server validates authenticated state-owner reports, replaces exactly one
  public slice, advances a revision only when public state changes, and sends
  the accepted operation to monitored subscribers. It also emits lightweight
  heartbeats to remote reducer clients so they can detect a silent partition
  without polling snapshots. It never issues lifecycle commands or performs
  subsystem work.
  """

  use GenServer

  alias NervesGate.DeviceState.{Public, Secret, State}
  alias NervesGate.Identity
  alias NervesGate.Subscribers

  @heartbeat_interval 1_000

  defstruct [:state, :boot_id, :owners, :heartbeat_interval, revision: 0, subscribers: %{}]

  @type snapshot :: %{
          node: node(),
          boot_id: String.t(),
          revision: non_neg_integer(),
          state: State.t(),
          hydrated: boolean()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec state(GenServer.server()) :: State.t()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @type subscriber :: pid()

  @spec subscribe(subscriber(), GenServer.server(), timeout()) :: {:ok, snapshot()}
  def subscribe(subscriber \\ self(), server \\ __MODULE__, timeout \\ 5_000)

  def subscribe(subscriber, server, timeout) when is_pid(subscriber),
    do: GenServer.call(server, {:subscribe, subscriber, false}, timeout)

  @doc false
  @spec subscribe_remote(subscriber(), GenServer.server(), timeout()) :: {:ok, snapshot()}
  def subscribe_remote(subscriber, server, timeout \\ 5_000) when is_pid(subscriber),
    do: GenServer.call(server, {:subscribe, subscriber, true}, timeout)

  @spec unsubscribe(subscriber(), GenServer.server()) :: :ok
  def unsubscribe(subscriber \\ self(), server \\ __MODULE__) when is_pid(subscriber),
    do: GenServer.call(server, {:unsubscribe, subscriber})

  @spec hydrated?(GenServer.server()) :: boolean()
  def hydrated?(server \\ __MODULE__), do: GenServer.call(server, :hydrated?)

  @impl true
  def init(options) do
    public_state = Keyword.get(options, :initial_state, State.new())
    public_state = maybe_bootstrap_device(public_state, options)

    server = %__MODULE__{
      state: public_state,
      boot_id: Keyword.get_lazy(options, :boot_id, &new_boot_id/0),
      owners: options |> Keyword.fetch!(:owners) |> Map.new(),
      heartbeat_interval: Keyword.get(options, :heartbeat_interval, @heartbeat_interval)
    }

    schedule_heartbeat(server)
    {:ok, server}
  end

  @impl true
  def handle_call(:state, _from, server), do: {:reply, server.state, server}
  def handle_call(:snapshot, _from, server), do: {:reply, snapshot_from(server), server}
  def handle_call(:hydrated?, _from, server), do: {:reply, State.hydrated?(server.state), server}

  def handle_call({:subscribe, subscriber, heartbeat?}, _from, server) do
    subscribers = Subscribers.add(server.subscribers, subscriber, %{heartbeat: heartbeat?})

    subscribers =
      if heartbeat?,
        do: update_in(subscribers[subscriber], &Map.put(&1, :heartbeat, true)),
        else: subscribers

    server = %{server | subscribers: subscribers}
    {:reply, {:ok, snapshot_from(server)}, server}
  end

  def handle_call({:unsubscribe, subscriber}, _from, server) do
    subscribers = Subscribers.remove(server.subscribers, subscriber)
    {:reply, :ok, %{server | subscribers: subscribers}}
  end

  def handle_call({:publish, {:state_reported, source, _value} = report}, {caller, _tag}, server) do
    case publish_report(server, caller, source, report) do
      {:ok, server} -> {:reply, :ok, server}
      {:error, reason} -> {:reply, {:error, reason}, server}
    end
  end

  def handle_call({:publish, _invalid}, _from, server),
    do: {:reply, {:error, :invalid_event}, server}

  @impl true
  def handle_info(:heartbeat, server) do
    broadcast_heartbeat(server)
    schedule_heartbeat(server)
    {:noreply, server}
  end

  def handle_info({:DOWN, reference, :process, subscriber, _reason}, server) do
    subscribers = Subscribers.down(server.subscribers, subscriber, reference)
    {:noreply, %{server | subscribers: subscribers}}
  end

  defp publish_report(server, caller, source, report) do
    with :ok <- authenticate(server, source, caller),
         :ok <- validate_public(report),
         {:ok, operation} <- State.operation(report),
         {:ok, new_state} <- State.reduce(server.state, operation) do
      if new_state == server.state do
        {:ok, server}
      else
        revision = server.revision + 1
        broadcast(server, revision, operation)
        {:ok, %{server | state: new_state, revision: revision}}
      end
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_state}
    end
  end

  defp validate_public({:state_reported, _source, value}) do
    cond do
      Secret.contains?(value) -> {:error, :secret_detected}
      Public.public?(value) -> :ok
      true -> {:error, :invalid_state}
    end
  end

  defp authenticate(%{owners: owners}, source, caller) do
    case Map.fetch(owners, source) do
      {:ok, owner} ->
        if resolve_owner(owner) == caller and node(caller) == node(),
          do: :ok,
          else: {:error, :not_owner}

      :error ->
        {:error, :not_owner}
    end
  end

  defp resolve_owner(owner) when is_pid(owner), do: owner

  defp resolve_owner(owner) do
    GenServer.whereis(owner)
  catch
    :exit, _reason -> nil
  end

  defp broadcast(server, revision, operation) do
    message = {:device_state_operation, node(), server.boot_id, revision, operation}
    Enum.each(server.subscribers, fn {subscriber, _metadata} -> send(subscriber, message) end)
  end

  defp broadcast_heartbeat(server) do
    message = {:device_state_heartbeat, node(), server.boot_id, server.revision}

    Enum.each(server.subscribers, fn
      {subscriber, %{heartbeat: true}} -> send(subscriber, message)
      {_subscriber, _metadata} -> :ok
    end)
  end

  defp snapshot_from(server) do
    %{
      node: node(),
      boot_id: server.boot_id,
      revision: server.revision,
      state: server.state,
      hydrated: State.hydrated?(server.state)
    }
  end

  defp maybe_bootstrap_device(%State{device: nil} = state, options) do
    device = Keyword.get_lazy(options, :device, &device_identity/0)
    {:ok, state} = State.reduce(state, {:put, :device, device})
    state
  end

  defp maybe_bootstrap_device(%State{} = state, _options), do: state

  defp device_identity do
    identity = Identity.get()

    %{
      device_id: identity.machine_id,
      name: identity.hostname,
      firmware_version: Application.spec(:nerves_gate, :vsn) |> to_string()
    }
  end

  defp schedule_heartbeat(%{heartbeat_interval: interval}) do
    Process.send_after(self(), :heartbeat, interval)
  end

  defp new_boot_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end

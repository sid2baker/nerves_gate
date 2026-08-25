defmodule NervesGate.DeviceState.Server do
  @moduledoc """
  Orders and distributes canonical secret-free public state.

  The server validates authenticated state-owner reports, replaces exactly one
  public slice, advances a revision only when public state changes, and sends
  the accepted event to monitored subscribers. It never issues lifecycle
  commands or performs subsystem work.
  """

  use GenServer

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.State
  alias NervesGate.Identity

  defstruct [:state, :boot_id, :owners, revision: 0, subscribers: %{}]

  @type snapshot :: %{
          boot_id: String.t(),
          revision: non_neg_integer(),
          state: State.t(),
          hydrated: boolean()
        }

  @default_owners %{
    configuration: NervesGate.Gateway.Configuration,
    commissioning: NervesGate.Commissioning,
    internet: NervesGate.Internet,
    tailnet: NervesGate.Tailnet,
    subnet_router: NervesGate.SubnetRouter,
    ssh: NervesGate.SSH,
    cluster: NervesGate.Cluster,
    alarms: NervesGate.Alarms.Runtime
  }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @spec state(GenServer.server()) :: State.t()
  def state(server \\ __MODULE__), do: GenServer.call(server, :state)

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @type subscriber :: pid() | {:finitomata, pid()}

  @spec subscribe(subscriber(), GenServer.server()) :: {:ok, snapshot()}
  def subscribe(subscriber \\ self(), server \\ __MODULE__)

  def subscribe(subscriber, server) when is_pid(subscriber),
    do: GenServer.call(server, {:subscribe, subscriber, :message})

  def subscribe({:finitomata, subscriber}, server) when is_pid(subscriber),
    do: GenServer.call(server, {:subscribe, subscriber, :finitomata})

  @spec hydrated?(GenServer.server()) :: boolean()
  def hydrated?(server \\ __MODULE__), do: GenServer.call(server, :hydrated?)

  @impl true
  def init(options) do
    public_state = Keyword.get(options, :initial_state, State.new())
    public_state = maybe_bootstrap_device(public_state, options)

    {:ok,
     %__MODULE__{
       state: public_state,
       boot_id: Keyword.get_lazy(options, :boot_id, &new_boot_id/0),
       owners: Map.merge(@default_owners, Map.new(Keyword.get(options, :owners, %{})))
     }}
  end

  @impl true
  def handle_call(:state, _from, server), do: {:reply, server.state, server}
  def handle_call(:snapshot, _from, server), do: {:reply, snapshot_from(server), server}
  def handle_call(:hydrated?, _from, server), do: {:reply, State.hydrated?(server.state), server}

  def handle_call({:subscribe, subscriber, delivery}, _from, server) do
    server = monitor_subscriber(server, subscriber, delivery)
    {:reply, {:ok, snapshot_from(server)}, server}
  end

  def handle_call({:publish, {:state_reported, source, _value} = event}, {caller, _tag}, server) do
    case publish_event(server, caller, source, event) do
      {:ok, server} -> {:reply, :ok, server}
      {:error, reason} -> {:reply, {:error, reason}, server}
    end
  end

  def handle_call({:publish, _invalid}, _from, server),
    do: {:reply, {:error, :invalid_event}, server}

  @impl true
  def handle_info({:DOWN, reference, :process, subscriber, _reason}, server) do
    case Map.get(server.subscribers, subscriber) do
      %{reference: ^reference} ->
        {:noreply, %{server | subscribers: Map.delete(server.subscribers, subscriber)}}

      _other ->
        {:noreply, server}
    end
  end

  defp publish_event(server, caller, source, event) do
    with :ok <- authenticate(server, source, caller),
         :ok <- validate_public(event),
         {:ok, new_state} <- State.apply_event(server.state, event) do
      if new_state == server.state do
        {:ok, server}
      else
        revision = server.revision + 1
        broadcast(server, revision, event)
        {:ok, %{server | state: new_state, revision: revision}}
      end
    else
      {:error, reason} -> {:error, reason}
      :error -> {:error, :invalid_state}
    end
  end

  defp validate_public({:state_reported, _source, value}) do
    cond do
      NervesGate.Secret.contains?(value) -> {:error, :secret_detected}
      DeviceState.public?(value) -> :ok
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

  defp broadcast(server, revision, event) do
    Enum.each(server.subscribers, fn
      {subscriber, %{delivery: :message}} ->
        send(subscriber, {:device_state_event, node(), server.boot_id, revision, event})

      {subscriber, %{delivery: :finitomata}} ->
        GenServer.cast(
          subscriber,
          {:device_state_event_received,
           %{node: node(), boot_id: server.boot_id, revision: revision, event: event}}
        )
    end)
  end

  defp monitor_subscriber(server, subscriber, delivery) do
    case Map.fetch(server.subscribers, subscriber) do
      {:ok, metadata} ->
        %{
          server
          | subscribers: Map.put(server.subscribers, subscriber, %{metadata | delivery: delivery})
        }

      :error ->
        metadata = %{reference: Process.monitor(subscriber), delivery: delivery}
        %{server | subscribers: Map.put(server.subscribers, subscriber, metadata)}
    end
  end

  defp snapshot_from(server) do
    %{
      boot_id: server.boot_id,
      revision: server.revision,
      state: server.state,
      hydrated: State.hydrated?(server.state)
    }
  end

  defp maybe_bootstrap_device(%State{device: nil} = state, options) do
    device = Keyword.get_lazy(options, :device, &device_identity/0)
    {:ok, state} = State.apply_event(state, {:state_reported, :device, device})
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

  defp new_boot_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end
end

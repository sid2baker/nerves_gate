defmodule NervesGate.Session do
  @moduledoc """
  Disposable live client projection over the local gateway and its fleet.

  A session atomically joins the local DeviceState stream, installs the current
  remote-replica cache, and then owns all reducer and resynchronization work for
  one client. The client receives complete state updates and never handles
  revisions, boot IDs, or reducer operations itself.
  """

  use GenServer

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.Replica.Supervisor, as: ReplicaSupervisor
  alias NervesGate.DeviceState.State

  @topic "device_state"

  @type fleet :: %{local: DeviceState.snapshot(), replicas: %{String.t() => map()}}

  @doc false
  def child_spec(options) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [options]},
      restart: :temporary
    }
  end

  @spec start(pid(), keyword()) :: DynamicSupervisor.on_start_child()
  def start(client, options \\ []) when is_pid(client) do
    DynamicSupervisor.start_child(
      NervesGate.Session.DynamicSupervisor,
      {__MODULE__, [{:client, client} | options]}
    )
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @spec state(GenServer.server()) :: fleet()
  def state(session), do: GenServer.call(session, :state)

  @spec configured?(GenServer.server()) :: boolean()
  def configured?(session) do
    case state(session).local.state.configuration do
      %{configured: configured} -> configured
      _unhydrated -> false
    end
  end

  @spec actor_for_ip(GenServer.server(), String.t()) :: map()
  def actor_for_ip(session, remote_ip) do
    peer =
      case state(session).local.state.tailnet do
        %{peers: peers} -> Enum.find(peers, &(&1.ipv4 == remote_ip))
        _unhydrated -> nil
      end

    %{ip: remote_ip, name: (peer && peer.hostname) || "tailnet user"}
  end

  @spec discovery(GenServer.server()) :: map()
  def discovery(session) do
    state = state(session).local.state
    device = state.device || %{}
    tailnet = state.tailnet
    cluster = state.cluster

    %{
      gateway_id: Map.get(device, :device_id),
      hostname: (tailnet && tailnet.hostname) || Map.get(device, :name),
      cluster_group: cluster && cluster.group
    }
  end

  @spec status(GenServer.server() | fleet()) :: map()
  def status(session) when is_pid(session), do: session |> state() |> status()

  def status(%{local: _local, replicas: _replicas} = fleet) do
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

  @impl true
  def init(options) do
    client = Keyword.fetch!(options, :client)
    server = Keyword.get(options, :device_state, NervesGate.DeviceState.Server)
    replicas = Keyword.get(options, :replicas, &ReplicaSupervisor.replicas/0)
    pubsub = Keyword.get(options, :pubsub, NervesGate.PubSub)
    topic = Keyword.get(options, :topic, @topic)

    :ok = Phoenix.PubSub.subscribe(pubsub, topic)
    {:ok, local} = DeviceState.subscribe(self(), server)

    {:ok,
     %{
       client: client,
       client_monitor: Process.monitor(client),
       device_state_server: server,
       replicas: replicas,
       fleet: %{local: local, replicas: replicas.()}
     }}
  end

  @impl true
  def handle_call(:state, _from, session) do
    session = refresh_current(session)
    {:reply, session.fleet, session}
  end

  @impl true
  def handle_info(
        {:device_state_event, _node, boot_id, revision, event},
        %{fleet: %{local: %{boot_id: boot_id, revision: previous} = local} = fleet} = session
      )
      when revision == previous + 1 do
    case State.apply_event(local.state, event) do
      {:ok, state} ->
        local = %{local | state: state, revision: revision}
        session = %{session | fleet: %{fleet | local: local}}
        {:noreply, notify(session)}

      :error ->
        {:noreply, resynchronize(session)}
    end
  end

  def handle_info(
        {:device_state_event, _node, boot_id, revision, _event},
        %{fleet: %{local: %{boot_id: boot_id, revision: current}}} = session
      )
      when revision <= current,
      do: {:noreply, session}

  def handle_info({:device_state_event, _node, _boot_id, _revision, _event}, session) do
    {:noreply, resynchronize(session)}
  end

  def handle_info({:replica_changed, device_id, replica}, session) do
    replicas = Map.put(session.fleet.replicas, device_id, replica)

    if replicas == session.fleet.replicas do
      {:noreply, session}
    else
      session = put_in(session.fleet.replicas, replicas)
      {:noreply, notify(session)}
    end
  end

  def handle_info(
        {:DOWN, reference, :process, client, _reason},
        %{client: client, client_monitor: reference} = session
      ) do
    {:stop, :normal, session}
  end

  def handle_info(_message, session), do: {:noreply, session}

  defp resynchronize(session) do
    {:ok, local} = DeviceState.subscribe(self(), session.device_state_server)
    session = put_in(session.fleet.local, local)
    notify(session)
  end

  defp refresh_current(session) do
    fleet = %{
      local: DeviceState.snapshot(session.device_state_server),
      replicas: session.replicas.()
    }

    %{session | fleet: fleet}
  end

  defp notify(session) do
    send(session.client, {:nerves_gate_state_changed, self(), session.fleet})
    session
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

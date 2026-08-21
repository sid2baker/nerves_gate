defmodule NervesGate.DeviceState.Server do
  @moduledoc "Single authoritative owner and operation sequencer for this device's public state."

  use GenServer

  alias NervesGate.Alarms
  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Device
  alias NervesGate.DeviceState.Public
  alias NervesGate.DeviceState.Snapshot
  alias NervesGate.Identity
  alias NervesGate.Internet.Monitor
  alias NervesGate.Tailnet.Observer

  defstruct [:public, :boot_id, revision: 0, clients: %{}]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec public(GenServer.server()) :: Public.t()
  def public(server \\ __MODULE__), do: GenServer.call(server, :public)

  @spec snapshot(GenServer.server()) :: Snapshot.t()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec join(pid(), GenServer.server()) :: {:ok, Snapshot.t()}
  def join(client, server \\ __MODULE__) when is_pid(client) do
    GenServer.call(server, {:join, client})
  end

  @spec apply_operation(Public.operation(), GenServer.server()) :: :ok
  def apply_operation(operation, server \\ __MODULE__) do
    GenServer.call(server, {:apply_operation, operation})
  end

  @spec alarm_transition(Alarmist.Event.t()) :: :ok
  def alarm_transition(%Alarmist.Event{} = event) do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, {:alarm_transition, event})
    :ok
  end

  @impl true
  def init(options) do
    if Keyword.get(options, :subscribe, true), do: subscribe_sources()
    boot_id = Keyword.get_lazy(options, :boot_id, &new_boot_id/0)

    public =
      Keyword.get_lazy(options, :initial_public, fn ->
        build_public(boot_id)
      end)

    {:ok, %__MODULE__{public: public, boot_id: boot_id}}
  end

  @impl true
  def handle_call(:public, _from, state), do: {:reply, state.public, state}
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from(state), state}

  def handle_call({:join, client}, _from, state) do
    state = monitor_client(state, client)
    {:reply, {:ok, snapshot_from(state)}, state}
  end

  def handle_call({:apply_operation, operation}, _from, state) do
    {:reply, :ok, apply_local_operation(state, operation)}
  end

  @impl true
  def handle_cast({:alarm_transition, event}, state) do
    state =
      case Alarms.public_event(event) do
        {:set, alarm} -> apply_local_operation(state, {:alarm_set, alarm})
        {:clear, id} -> apply_local_operation(state, {:alarm_cleared, id})
        :ignore -> state
      end

    {:noreply, state}
  end

  @impl true
  def handle_info({:device_changed, %{"name" => name}}, state) do
    {:noreply, apply_local_operation(state, {:name_changed, name})}
  end

  def handle_info({:internet_changed, status}, state) do
    {:noreply, apply_local_operation(state, {:internet_changed, public_internet(status)})}
  end

  def handle_info({:tailnet_changed, status}, state) do
    {:noreply, apply_local_operation(state, {:tailnet_changed, public_tailnet(status)})}
  end

  def handle_info({:cluster_changed, status}, state) do
    {:noreply, apply_local_operation(state, {:cluster_changed, public_cluster(status)})}
  end

  def handle_info({:DOWN, reference, :process, client, _reason}, state) do
    case Map.get(state.clients, client) do
      ^reference -> {:noreply, %{state | clients: Map.delete(state.clients, client)}}
      _other -> {:noreply, state}
    end
  end

  defp apply_local_operation(state, operation) do
    public = Public.reduce(state.public, operation)

    if public == state.public do
      state
    else
      revision = state.revision + 1
      message = {:device_state_operation, node(), state.boot_id, revision, operation}
      Enum.each(Map.keys(state.clients), &send(&1, message))
      Phoenix.PubSub.broadcast(NervesGate.PubSub, "device_state", {:local_state_changed, public})
      %{state | public: public, revision: revision}
    end
  end

  defp monitor_client(state, client) do
    case Map.fetch(state.clients, client) do
      {:ok, _reference} -> state
      :error -> %{state | clients: Map.put(state.clients, client, Process.monitor(client))}
    end
  end

  defp snapshot_from(state) do
    %Snapshot{boot_id: state.boot_id, revision: state.revision, data: state.public}
  end

  defp build_public(boot_id) do
    identity = Identity.get()
    profile = safe(Device, :get, %{"name" => identity.hostname})

    %Public{
      device_id: identity.machine_id,
      name: Map.get(profile, "name", identity.hostname),
      boot_id: boot_id,
      firmware_version: firmware_version(),
      internet: public_internet(safe(Monitor, :status, %{online: false, reason: :starting})),
      tailnet: public_tailnet(safe(Observer, :status, %{})),
      cluster: public_cluster(safe(ClusterManager, :status, %{})),
      alarms: Alarms.active()
    }
    |> Public.reduce({:internet_changed, public_internet(safe(Monitor, :status, %{}))})
  end

  defp public_internet(status) do
    %{
      status: if(Map.get(status, :online, false), do: :online, else: :failed),
      reason: Map.get(status, :reason)
    }
  end

  defp public_tailnet(status) do
    observed_status = if Map.get(status, :online, false), do: :online, else: :offline

    %{
      status: observed_status,
      observed_status: observed_status,
      authenticated: Map.get(status, :authenticated, :unknown),
      hostname: Map.get(status, :hostname),
      ipv4: Map.get(status, :ipv4)
    }
  end

  defp public_cluster(status) do
    enabled = Map.get(status, :enabled, false)
    online = Map.get(status, :online, false)

    %{
      status: cluster_runtime_status(enabled, online),
      runtime_status: cluster_runtime_status(enabled, online),
      enabled: enabled,
      node: encode_node(Map.get(status, :node)),
      connected: status |> Map.get(:connected, []) |> Enum.map(&to_string/1) |> Enum.sort()
    }
  end

  defp cluster_runtime_status(false, _online), do: :disabled
  defp cluster_runtime_status(true, true), do: :online
  defp cluster_runtime_status(true, false), do: :failed

  defp encode_node(nil), do: nil
  defp encode_node(node), do: to_string(node)

  defp firmware_version do
    Application.spec(:nerves_gate, :vsn) |> to_string()
  end

  defp new_boot_id do
    16 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
  end

  defp subscribe_sources do
    Enum.each(~w(device internet tailnet cluster), fn topic ->
      Phoenix.PubSub.subscribe(NervesGate.PubSub, topic)
    end)
  end

  defp safe(module, function, fallback) do
    apply(module, function, [])
  catch
    _kind, _reason -> fallback
  end
end

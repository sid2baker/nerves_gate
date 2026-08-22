defmodule NervesGate.DeviceState.Server do
  @moduledoc """
  Owns and sequences this gateway's canonical device data.

  Every accepted operation is applied to the local `%DeviceState.Data{}` first
  and then sent to all joined clients. Consequently every client observes the
  same operations in the same order and can maintain an identical local copy.
  """

  use GenServer

  alias NervesGate.Alarms
  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Device
  alias NervesGate.DeviceState.Data
  alias NervesGate.Identity
  alias NervesGate.Internet.Monitor
  alias NervesGate.Tailnet.Observer

  defstruct [:data, :boot_id, revision: 0, clients: %{}]

  @type snapshot :: %{
          boot_id: String.t(),
          revision: non_neg_integer(),
          data: Data.t()
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec data(GenServer.server()) :: Data.t()
  def data(server \\ __MODULE__), do: GenServer.call(server, :data)

  @spec snapshot(GenServer.server()) :: snapshot()
  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  @spec join(pid(), GenServer.server()) :: {:ok, snapshot()}
  def join(client, server \\ __MODULE__) when is_pid(client) do
    GenServer.call(server, {:join, client})
  end

  @spec apply_operation(Data.operation(), GenServer.server()) :: :ok | :error
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
    data = Keyword.get_lazy(options, :initial_data, &build_data/0)
    {:ok, %__MODULE__{data: data, boot_id: boot_id}}
  end

  @impl true
  def handle_call(:data, _from, state), do: {:reply, state.data, state}
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_from(state), state}

  def handle_call({:join, client}, _from, state) do
    state = monitor_client(state, client)
    {:reply, {:ok, snapshot_from(state)}, state}
  end

  def handle_call({:apply_operation, operation}, _from, state) do
    case apply_local_operation(state, operation) do
      {:ok, state} -> {:reply, :ok, state}
      :error -> {:reply, :error, state}
    end
  end

  @impl true
  def handle_cast({:alarm_transition, event}, state) do
    operation =
      case Alarms.public_event(event) do
        {:set, alarm} -> {:set_alarm, :alarms, alarm}
        {:clear, id} -> {:clear_alarm, :alarms, id}
        :ignore -> nil
      end

    {:noreply, maybe_apply_local_operation(state, operation)}
  end

  @impl true
  def handle_info({:device_changed, %{"name" => name}}, state) do
    {:noreply, apply_valid_local_operation(state, {:set_name, :device, name})}
  end

  def handle_info({:internet_changed, status}, state) do
    operation = {:set_internet, :internet, internet_data(status)}
    {:noreply, apply_valid_local_operation(state, operation)}
  end

  def handle_info({:tailnet_changed, status}, state) do
    operation = {:set_tailnet, :tailnet, tailnet_data(status)}
    {:noreply, apply_valid_local_operation(state, operation)}
  end

  def handle_info({:cluster_changed, status}, state) do
    operation = {:set_cluster, :cluster, cluster_data(status)}
    {:noreply, apply_valid_local_operation(state, operation)}
  end

  def handle_info({:DOWN, reference, :process, client, _reason}, state) do
    case Map.get(state.clients, client) do
      ^reference -> {:noreply, %{state | clients: Map.delete(state.clients, client)}}
      _other -> {:noreply, state}
    end
  end

  defp maybe_apply_local_operation(state, nil), do: state

  defp maybe_apply_local_operation(state, operation),
    do: apply_valid_local_operation(state, operation)

  defp apply_valid_local_operation(state, operation) do
    {:ok, state} = apply_local_operation(state, operation)
    state
  end

  defp apply_local_operation(state, operation) do
    case Data.apply_operation(state.data, operation) do
      {:ok, data, _actions} when data == state.data ->
        {:ok, state}

      {:ok, data, actions} ->
        revision = state.revision + 1
        message = {:device_state_operation, node(), state.boot_id, revision, operation}
        Enum.each(Map.keys(state.clients), &send(&1, message))
        execute_actions(actions, data)
        {:ok, %{state | data: data, revision: revision}}

      :error ->
        :error
    end
  end

  defp execute_actions(actions, data) do
    Enum.each(actions, fn :broadcast ->
      Phoenix.PubSub.local_broadcast(
        NervesGate.PubSub,
        "device_state",
        {:local_state_changed, data}
      )
    end)
  end

  defp monitor_client(state, client) do
    case Map.fetch(state.clients, client) do
      {:ok, _reference} -> state
      :error -> %{state | clients: Map.put(state.clients, client, Process.monitor(client))}
    end
  end

  defp snapshot_from(state) do
    %{boot_id: state.boot_id, revision: state.revision, data: state.data}
  end

  defp build_data do
    identity = Identity.get()
    profile = Device.get()

    Data.new(
      device_id: identity.machine_id,
      name: Map.get(profile, "name", identity.hostname),
      firmware_version: firmware_version(),
      internet: internet_data(Monitor.status()),
      tailnet: tailnet_data(Observer.status()),
      cluster: cluster_data(ClusterManager.status()),
      alarms: Alarms.active()
    )
  end

  defp internet_data(status) do
    %{
      status: if(Map.get(status, :online, false), do: :online, else: :failed),
      reason: Map.get(status, :reason)
    }
  end

  defp tailnet_data(status) do
    observed_status = if Map.get(status, :online, false), do: :online, else: :offline

    %{
      observed_status: observed_status,
      authenticated: Map.get(status, :authenticated, :unknown),
      hostname: Map.get(status, :hostname),
      ipv4: Map.get(status, :ipv4)
    }
  end

  defp cluster_data(status) do
    enabled = Map.get(status, :enabled, false)
    online = Map.get(status, :online, false)

    %{
      runtime_status: cluster_runtime_status(enabled, online),
      enabled: enabled,
      group: Map.get(status, :group),
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
end

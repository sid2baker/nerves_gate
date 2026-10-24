defmodule NervesGate.SDKBackend do
  @moduledoc "Device implementation of the read-only SDK views and process-owned bus operations."
  use GenServer
  @behaviour NervesGateSDK.Backend

  alias NervesGate.{Buses, Equipment, Network, Storage}
  alias NervesGate.Equipment.Subnet
  alias NervesGateSDK.Events.Event
  alias NervesGateSDK.System.Info

  @topics [:system, :network, :storage, :equipment]
  @bus_operations [
    :can_interfaces,
    :can_send,
    :can_subscribe,
    :can_unsubscribe,
    :rs485_ports,
    :rs485_claim,
    :rs485_write,
    :rs485_release
  ]

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  # Call Buses from the application process, not from this server: subscriptions
  # and exclusive UART claims must belong to the actual caller.
  @impl NervesGateSDK.Backend
  def call(operation, arguments) when operation in @bus_operations,
    do: available(fn -> Buses.sdk(operation, arguments) end)

  def call(:storage_data_dir, [app]), do: Storage.data_dir(app)

  def call(operation, arguments),
    do: available(fn -> GenServer.call(__MODULE__, {operation, arguments}) end)

  @impl GenServer
  def init(_) do
    identity = %Info{
      id: Nerves.Runtime.serial_number(),
      model: to_string(NervesGate.System.info().target),
      firmware_version: NervesGate.System.info().firmware,
      sdk_version: to_string(Application.spec(:nerves_gate_sdk, :vsn))
    }

    send(self(), :bind)
    send(self(), :poll)
    {:ok, %{identity: identity, subscribers: %{}, monitors: %{}, values: %{}, refreshing?: false}}
  end

  @impl GenServer
  def handle_call({:events_subscribe, [topic]}, {pid, _}, state) when topic in @topics do
    monitors = Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)
    subscribers = Map.update(state.subscribers, topic, MapSet.new([pid]), &MapSet.put(&1, pid))
    {:reply, :ok, %{state | monitors: monitors, subscribers: subscribers}}
  end

  def handle_call({:events_unsubscribe, [topic]}, {pid, _}, state) when topic in @topics do
    subscribers = Map.update(state.subscribers, topic, MapSet.new(), &MapSet.delete(&1, pid))
    {:reply, :ok, unmonitor_unused(%{state | subscribers: subscribers}, pid)}
  end

  def handle_call({operation, []}, _, state)
      when operation in [:system_info, :network_interfaces, :equipment_list, :storage_status] do
    topic =
      case operation do
        :system_info -> :system
        :network_interfaces -> :network
        :equipment_list -> :equipment
        :storage_status -> :storage
      end

    {:reply, query(topic, state), state}
  end

  def handle_call(_, _, state), do: {:reply, {:error, :invalid_request}, state}

  @impl GenServer
  def handle_info(:bind, state) do
    # Rebind after a domain or PropertyTable restart. No remote/admin observations.
    available(fn -> Network.observe() end)
    available(fn -> Equipment.observe() end)
    Process.send_after(self(), :bind, 5_000)
    {:noreply, state}
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, 1_000)
    {:noreply, refresh(state)}
  end

  def handle_info(:refresh, state), do: {:noreply, refresh(%{state | refreshing?: false})}
  def handle_info(%PropertyTable.Event{}, state), do: {:noreply, dirty(state)}

  def handle_info({table, _path, _, _, _}, state)
      when table in [VintageNet, NervesGate.Properties],
      do: {:noreply, dirty(state)}

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    if state.monitors[pid] == ref do
      subscribers =
        Map.new(state.subscribers, fn {topic, pids} -> {topic, MapSet.delete(pids, pid)} end)

      {:noreply, %{state | subscribers: subscribers, monitors: Map.delete(state.monitors, pid)}}
    else
      {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  defp query(:system, state) do
    uptime =
      System.monotonic_time(:millisecond) -
        System.convert_time_unit(:erlang.system_info(:start_time), :native, :millisecond)

    {:ok, %{state.identity | uptime_ms: max(0, uptime)}}
  end

  defp query(:storage, _), do: Storage.status()

  defp query(:network, _) do
    available(fn ->
      case Network.status() do
        %{observed: observed} when is_map(observed) ->
          interfaces =
            Enum.map(observed.ports, &interface(&1, :ethernet)) ++
              [
                interface(observed.bridge, :other),
                interface(observed.usb, :usb),
                interface(observed.cellular, :cellular)
              ]

          {:ok, Enum.reject(interfaces, &is_nil/1)}

        _ ->
          {:error, :unavailable}
      end
    end)
  end

  defp query(:equipment, _) do
    available(fn ->
      equipment = Equipment.status()

      # Do not expose observations from a previous network scope during a trial.
      with {:ok, scope} <- Subnet.from_status(Network.status()),
           true <- equipment.available and equipment.scope == scope do
        {:ok, Enum.map(equipment.entries, &device(&1, scope))}
      else
        _ -> {:ok, []}
      end
    end)
  end

  defp device(entry, scope) do
    %NervesGateSDK.Equipment.Device{
      id: entry.id,
      interface: scope.interface,
      label: entry.label,
      address: entry.ip,
      # A neighbor-cache entry is not proof of current reachability.
      reachable?: false
    }
  end

  defp interface(nil, _kind), do: nil

  defp interface(port, kind) do
    %NervesGateSDK.Network.Interface{
      id: port.name,
      kind: kind,
      state:
        cond do
          not port.present -> :down
          port.link -> :up
          port.link == false -> :down
          true -> :unknown
        end,
      addresses: Enum.map(port.addresses, & &1.address),
      internet?:
        port.present and port.link and port.connection == :internet and port.addresses != []
    }
  end

  defp dirty(%{refreshing?: true} = state), do: state

  defp dirty(state) do
    Process.send_after(self(), :refresh, 20)
    %{state | refreshing?: true}
  end

  defp refresh(state) do
    Enum.reduce(@topics, state, fn topic, state ->
      case query(topic, state) do
        {:ok, value} -> notify(state, topic, value)
        {:error, _} -> state
      end
    end)
  end

  defp notify(state, topic, value) do
    if Map.get(state.values, topic) != value do
      for pid <- Map.get(state.subscribers, topic, MapSet.new()),
          do: send(pid, %Event{topic: topic, value: value})
    end

    %{state | values: Map.put(state.values, topic, value)}
  end

  defp unmonitor_unused(state, pid) do
    if Enum.any?(state.subscribers, fn {_, pids} -> MapSet.member?(pids, pid) end) do
      state
    else
      if ref = state.monitors[pid], do: Process.demonitor(ref, [:flush])
      %{state | monitors: Map.delete(state.monitors, pid)}
    end
  end

  defp available(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :unavailable}
  end
end

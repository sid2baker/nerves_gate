defmodule NervesGate.SDKBackend do
  @moduledoc "Typed SDK views and managed-generation resources, always owned by the actual calling PID."
  use GenServer
  @behaviour NervesGateSDK.Backend

  alias NervesGate.{Network, Storage}
  alias NervesGateSDK.Events.Event
  alias NervesGateSDK.System.Info

  @topics [:system, :network, :storage]
  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl NervesGateSDK.Backend
  def call(:hardware_resources, []),
    do: available(fn -> NervesGate.Plugins.resources() end)

  # These calls must also originate from the actual application process, never
  # this observation server or a Task acting as a caller proxy.
  def call(:network_claim_local, [interface, address, prefix]),
    do: available(fn -> local_result(Network.claim_local(interface, address, prefix)) end)

  def call(:network_local_status, []),
    do: available(fn -> local_result(Network.local_status()) end)

  def call(:network_advertise_local, [ref]),
    do: available(fn -> local_result(Network.advertise_local(ref)) end)

  def call(:network_release_local, [ref]),
    do: available(fn -> local_result(Network.release_local(ref)) end)

  def call(:storage_data_dir, [app]) do
    with {:ok, owner} <- NervesGate.Plugins.Owner.resolve(self()),
         true <- to_string(app) == owner.app do
      Storage.data_dir(app)
    else
      false -> {:error, :not_owner}
      error -> error
    end
  end

  def call(:io_register_input, [definition]),
    do: managed_io(:active, fn -> NervesGate.IO.register_input(definition) end)

  def call(:io_register_output, [definition, handler]),
    do: managed_io(:active, fn -> NervesGate.IO.register_output(definition, handler) end)

  def call(:io_publish_input, [id, value, quality]),
    do: managed_io(:release, fn -> NervesGate.IO.publish_input(id, value, quality) end)

  def call(:io_read_desired, [id]),
    do: managed_io(:release, fn -> NervesGate.IO.read_desired(id) end)

  def call(:io_input, [id]),
    do: managed_io(:release, fn -> NervesGate.IO.input(id) end)

  def call(:io_output, [id]),
    do: managed_io(:release, fn -> NervesGate.IO.output(id) end)

  def call(:io_subscribe, [id]),
    do: managed_io(:active, fn -> NervesGate.IO.subscribe(id) end)

  def call(:io_unsubscribe, [id]),
    do: managed_io(:release, fn -> NervesGate.IO.unsubscribe(id) end)

  def call(:io_claim_output, [id]),
    do: managed_io(:active, fn -> NervesGate.IO.claim_output(id) end)

  def call(:io_set_output, [id, value]),
    do: managed_io(:active, fn -> NervesGate.IO.set_output(id, value) end)

  def call(:io_release_output, [id]),
    do: managed_io(:release, fn -> NervesGate.IO.release_output(id) end)

  def call(operation, arguments),
    do: available(fn -> GenServer.call(__MODULE__, {operation, arguments}) end)

  defp managed_io(mode, fun) do
    available(fn ->
      with {:ok, _owner} <- NervesGate.Plugins.Owner.resolve(self(), mode), do: fun.()
    end)
  end

  defp local_result({:error, %{code: code}}), do: {:error, code}
  defp local_result(result), do: result

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

    {:ok,
     %{
       identity: identity,
       subscribers: %{},
       owners: %{},
       monitors: %{},
       values: %{},
       refreshing?: false
     }}
  end

  @impl GenServer
  def handle_call({:events_subscribe, [topic]}, {pid, _}, state) when topic in @topics do
    case NervesGate.Plugins.Owner.resolve(pid) do
      {:ok, owner} ->
        state =
          if state.owners[pid] && state.owners[pid] != owner,
            do: remove_owner(state, pid),
            else: state

        monitors = Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)

        subscribers =
          Map.update(state.subscribers, topic, MapSet.new([pid]), &MapSet.put(&1, pid))

        {:reply, :ok,
         %{
           state
           | monitors: monitors,
             subscribers: subscribers,
             owners: Map.put(state.owners, pid, owner)
         }}

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:drain_generation, tag}, _, state) do
    next =
      Enum.reduce(state.owners, state, fn {pid, owner}, state ->
        if NervesGate.Plugins.Loader.stale?(owner, tag), do: remove_owner(state, pid), else: state
      end)

    {:reply, :ok, next}
  end

  def handle_call({:events_unsubscribe, [topic]}, {pid, _}, state) when topic in @topics do
    subscribers = Map.update(state.subscribers, topic, MapSet.new(), &MapSet.delete(&1, pid))
    {:reply, :ok, unmonitor_unused(%{state | subscribers: subscribers}, pid)}
  end

  def handle_call({operation, []}, _, state)
      when operation in [:system_info, :network_interfaces, :storage_status] do
    topic =
      case operation do
        :system_info -> :system
        :network_interfaces -> :network
        :storage_status -> :storage
      end

    {:reply, query(topic, state), state}
  end

  def handle_call(_, _, state), do: {:reply, {:error, :invalid_request}, state}

  @impl GenServer
  def handle_info(:bind, state) do
    # Rebind after a domain or PropertyTable restart. No remote/admin observations.
    available(fn -> Network.observe() end)
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

      {:noreply,
       %{
         state
         | subscribers: subscribers,
           monitors: Map.delete(state.monitors, pid),
           owners: Map.delete(state.owners, pid)
       }}
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
    available(fn -> network_interfaces(Network.status()) end)
  end

  defp network_interfaces(%{observed: observed} = status) when is_map(observed) do
    assignments = NervesGate.Plugins.hardware()

    interfaces =
      Enum.map(observed.ports, &ethernet_interface(&1, status, assignments)) ++
        [
          interface(observed.bridge, :other),
          interface(observed.usb, :usb),
          interface(observed.cellular, :cellular)
        ]

    {:ok, Enum.reject(interfaces, &is_nil/1)}
  end

  defp network_interfaces(_) do
    {:error, :unavailable}
  end

  defp ethernet_interface(port, status, assignments) do
    local = Map.get(status, :local)

    role =
      get_in(NervesGate.Config.ports(status.config && status.config["network"]), [
        port.name,
        "role"
      ])

    setting = assignments.ports[port.name] || %{enabled: false, plugin: nil}

    %{
      interface(port, :ethernet)
      | plugin_enabled?: assignments.error == nil and role != "internet" and setting.enabled,
        assigned_plugin: setting.plugin,
        claimed?: local != nil and local.interface == port.name
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
          NervesGate.Plugins.Owner.matches?(pid, state.owners[pid]),
          do: send(pid, %Event{topic: topic, value: value})
    end

    %{state | values: Map.put(state.values, topic, value)}
  end

  defp unmonitor_unused(state, pid) do
    if Enum.any?(state.subscribers, fn {_, pids} -> MapSet.member?(pids, pid) end) do
      state
    else
      if ref = state.monitors[pid], do: Process.demonitor(ref, [:flush])
      %{state | monitors: Map.delete(state.monitors, pid), owners: Map.delete(state.owners, pid)}
    end
  end

  defp remove_owner(state, pid) do
    if ref = state.monitors[pid], do: Process.demonitor(ref, [:flush])

    %{
      state
      | owners: Map.delete(state.owners, pid),
        monitors: Map.delete(state.monitors, pid),
        subscribers:
          Map.new(state.subscribers, fn {topic, pids} -> {topic, MapSet.delete(pids, pid)} end)
    }
  end

  defp available(fun) do
    fun.()
  catch
    :exit, _ -> {:error, :unavailable}
  end
end

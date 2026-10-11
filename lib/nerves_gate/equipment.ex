defmodule NervesGate.Equipment do
  @moduledoc "Bounded Ethernet observations and labels. Network.Runtime owns active-scan exclusivity."
  use GenServer
  alias NervesGate.Equipment.{Labels, Linux, Subnet}
  alias NervesGate.{Error, Network, Observations}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def observe(server \\ __MODULE__), do: Observations.subscribe_runtime(server)
  def label(id, value, server \\ __MODULE__), do: GenServer.call(server, {:label, id, value})

  # Runs in the LAN runtime's bounded worker, not a second scan task. Monitoring
  # the worker clears the UI even if the runtime restarts or kills a timed-out scan.
  @doc false
  def scan(scope, server) do
    with {:ok, ref, {module, context}} <- GenServer.call(server, {:begin_scan, scope}) do
      result = module.scan(scope, context)
      GenServer.call(server, {:scan_result, ref, result})
    end
  end

  def unavailable,
    do: %{
      available: false,
      scope: nil,
      entries: [],
      operation: nil,
      last_scan: nil,
      error: Error.from(:equipment_unavailable),
      labels_error: nil
    }

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    {module, context} =
      adapter =
      Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :equipment_adapter))

    {labels, labels_error} =
      case module.load_labels(context) do
        {:ok, labels} -> {labels, nil}
        {:error, reason} -> {%{}, reason}
      end

    state = %{
      adapter: adapter,
      network: Keyword.get(opts, :network, Network),
      scope: nil,
      entries: %{},
      labels: labels,
      labels_error: labels_error,
      worker: nil,
      scan: nil,
      last_scan: nil,
      error: nil,
      poll_ms: Keyword.get(opts, :poll_ms, 5_000),
      effect_ms: Keyword.get(opts, :effect_ms, 2_000)
    }

    send(self(), :poll)
    {:ok, publish(state)}
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, public(state), state}
  def handle_call(:observations, _, state), do: {:reply, sources(), state}

  def handle_call({:label, id, value}, _, state) do
    entry = Enum.find_value(state.entries, fn {_, entry} -> if entry.id == id, do: entry end)

    with nil <- state.labels_error,
         %{label_key: key} <- entry,
         {:ok, labels} <- Labels.put(state.labels, key, value),
         {module, context} = state.adapter,
         :ok <- module.save_labels(labels, context) do
      {:reply, :ok, publish(%{state | labels: labels})}
    else
      {:error, _} = error -> {:reply, error, state}
      nil -> {:reply, {:error, :equipment_changed}, state}
      _ -> {:reply, {:error, :labels_unavailable}, state}
    end
  end

  def handle_call({:begin_scan, _}, _, %{scan: scan} = state) when not is_nil(scan),
    do: {:reply, {:error, :operation_in_progress}, state}

  def handle_call({:begin_scan, scope}, {pid, _}, state) do
    ref = Process.monitor(pid)
    state = state |> stop_poll() |> set_scope(scope)
    {:reply, {:ok, ref, state.adapter}, publish(%{state | scan: ref, error: nil})}
  end

  def handle_call({:scan_result, ref, result}, _, %{scan: ref} = state) do
    Process.demonitor(ref, [:flush])
    state = state |> apply_entries(result) |> Map.put(:scan, nil)

    state =
      if match?({:ok, _}, result),
        do: %{state | last_scan: System.system_time(:millisecond)},
        else: state

    reply =
      case result do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end

    {:reply, reply, publish(state)}
  end

  def handle_call({:scan_result, _, _}, _, state),
    do: {:reply, {:error, :equipment_changed}, state}

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, poll(state)}
  end

  def handle_info({ref, {scope, result}}, %{worker: %{task: %{ref: ref}, timer: timer}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(timer)
    state = %{state | worker: nil} |> set_scope(scope) |> apply_entries(result)
    {:noreply, publish(state)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{scan: ref} = state),
    do: {:noreply, publish(%{state | scan: nil, error: :scan_interrupted})}

  def handle_info(
        {:DOWN, ref, :process, _, _},
        %{worker: %{task: %{ref: ref}, timer: timer}} = state
      ) do
    Process.cancel_timer(timer)
    {:noreply, publish(%{state | worker: nil, error: :equipment_unavailable})}
  end

  def handle_info({:poll_timeout, ref}, %{worker: %{task: %{ref: ref}}} = state),
    do: {:noreply, publish(%{stop_poll(state) | error: :equipment_unavailable})}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: stop_poll(state)

  defp poll(%{worker: nil, scan: nil} = state) do
    {module, context} = state.adapter

    task =
      Task.async(fn ->
        case Subnet.from_status(Network.status(state.network)) do
          {:ok, scope} -> {scope, module.neighbors(scope, context)}
          {:error, reason} -> {nil, {:error, reason}}
        end
      end)

    timer = Process.send_after(self(), {:poll_timeout, task.ref}, state.effect_ms)
    %{state | worker: %{task: task, timer: timer}}
  end

  defp poll(state), do: state
  defp stop_poll(%{worker: nil} = state), do: state

  defp stop_poll(%{worker: worker} = state) do
    Task.shutdown(worker.task, :brutal_kill)
    Process.cancel_timer(worker.timer)
    %{state | worker: nil}
  end

  defp set_scope(%{scope: scope} = state, scope), do: state
  defp set_scope(state, scope), do: %{state | scope: scope, entries: %{}, last_scan: nil}

  defp apply_entries(state, {:error, reason}), do: %{state | error: reason}

  defp apply_entries(state, {:ok, entries}) do
    now = System.system_time(:millisecond)
    retained = Map.reject(state.entries, fn {_, entry} -> now - entry.observed_at > 900_000 end)
    entries = entries |> Enum.take(256) |> Enum.filter(&valid_entry?(&1, state.scope))

    merged =
      Enum.reduce(entries, retained, fn entry, acc ->
        id = digest("#{Subnet.key(state.scope)}:#{entry.ip}:#{String.downcase(entry.mac)}")
        previous = acc[id]

        entry =
          if previous && (previous.last_seen || 0) > (entry.last_seen || 0),
            do: %{entry | last_seen: previous.last_seen, source: previous.source},
            else: entry

        entry =
          Map.merge(entry, %{
            id: id,
            mac: String.downcase(entry.mac),
            observed_at: now,
            label_key: digest("#{Subnet.key(state.scope)}:#{String.downcase(entry.mac)}")
          })

        Map.put(acc, id, entry)
      end)

    bounded =
      merged
      |> Enum.sort_by(fn {id, entry} -> {-entry.observed_at, id} end)
      |> Enum.take(256)
      |> Map.new()

    %{state | entries: bounded, error: nil}
  end

  defp valid_entry?(%{ip: ip, mac: mac, last_seen: seen, source: source}, scope),
    do:
      Subnet.host?(scope, ip) and match?({:ok, _}, Linux.parse_mac(mac)) and
        (is_nil(seen) or is_integer(seen)) and
        source in ["neighbor cache", "ARP reply", "simulated"]

  defp valid_entry?(_, _), do: false

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp public(state) do
    entries =
      state.entries
      |> Map.values()
      |> Enum.sort_by(& &1.ip)
      |> Enum.map(fn entry ->
        entry
        |> Map.put(:label, state.labels[entry.label_key] || "")
        |> Map.drop([:label_key, :observed_at])
      end)

    %{
      available: true,
      scope: state.scope,
      entries: entries,
      operation: if(state.scan, do: :scan),
      last_scan: state.last_scan,
      error: state.error && Error.from(state.error),
      labels_error: state.labels_error && Error.from(state.labels_error)
    }
  end

  defp sources, do: [{Observations.table(), Observations.workflow("equipment", inspect(self()))}]

  defp publish(state) do
    Observations.put(Observations.workflow("equipment", inspect(self())), public(state))
    state
  end
end

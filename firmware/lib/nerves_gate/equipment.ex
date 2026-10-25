defmodule NervesGate.Equipment do
  @moduledoc """
  Equipment observations and local labels for the confirmed equipment subnet.

  ## Commands

  `label/2` saves a label and returns `:ok` after persistence, or `{:error, reason}`.
  `scan/0`, `share/0` and `unshare/0` reserve Network's LAN worker so these
  operations cannot overlap network reconfiguration.

  ## Queries and notifications

  `status/0` returns the scope, entries, scan progress and errors. Entries and
  labels are capped at 256 each; observations are not proof of reachability.
  `observe/0` subscribes the caller to inventory changes; reread status afterward.

  Passive discovery failures for a confirmed scope set
  `:equipment_discovery_unavailable`. A successful observation (even an empty
  inventory) or removing the equipment configuration clears it. Scan results,
  label commands and temporarily unknown network state do not clear that fault.
  """
  use GenServer
  alias NervesGate.{Alarms, Error, Network, Observations}
  alias NervesGate.Equipment.{Labels, Linux, Subnet}

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Save a label for an ID from status entries. At most 64 characters; empty text removes it."

  def label(id, value),
    do: Error.protect(fn -> GenServer.call(__MODULE__, {:label, id, value}) end)

  @doc "Read scoped entries, last scan, operation and errors. Does not initiate a scan."

  def status do
    NervesGate.Error.read(fn -> GenServer.call(__MODULE__, :status) end, &unavailable/0)
  end

  @doc "Subscribe the caller to inventory-change hints; read status to obtain current entries."

  def observe, do: Error.protect(fn -> Observations.subscribe_runtime(__MODULE__) end)

  @doc "Scan the confirmed subnet while reserving Network's LAN worker."
  def scan, do: Error.protect(fn -> GenServer.call(Network, :scan, 15_000) end)

  @doc "Advertise the confirmed dedicated equipment subnet after Network admission."
  def share,
    do: Error.protect(fn -> GenServer.call(Network, {:sharing, :sharing_enable, %{}}, 70_000) end)

  @doc "Withdraw equipment sharing without replacing other Tailscale preferences."
  def unshare,
    do:
      Error.protect(fn -> GenServer.call(Network, {:sharing, :sharing_disable, %{}}, 70_000) end)

  # Runs in Network's bounded worker. Monitoring clears progress when that worker dies.
  @doc false
  def perform_scan(scope) do
    with {:ok, ref} <- GenServer.call(__MODULE__, {:begin_scan, scope}) do
      result =
        case Linux.scan(scope) do
          {:ok, _} = result ->
            result

          {:error, _} ->
            {:error,
             Error.new(
               "scan_interrupted",
               "The scan was interrupted. Network settings were not changed."
             )}
        end

      GenServer.call(__MODULE__, {:scan_result, ref, result})
    end
  end

  @doc false
  def unavailable,
    do: %{
      available: false,
      scope: nil,
      entries: [],
      operation: nil,
      last_scan: nil,
      error: %{code: "equipment_unavailable", message: "Equipment observations are unavailable."},
      labels_error: nil
    }

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Alarms.register(__MODULE__, [:equipment_discovery_unavailable])

    {labels, labels_error} =
      case Linux.load_labels() do
        {:ok, labels} -> {labels, nil}
        {:error, reason} -> {%{}, reason}
      end

    state = %{
      name: __MODULE__,
      discovery_fault: nil,
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
         :ok <- Linux.save_labels(labels) do
      {:reply, :ok, publish(%{state | labels: labels})}
    else
      {:error, _} = error ->
        {:reply, error, state}

      nil ->
        {:reply,
         {:error,
          %{
            code: "equipment_changed",
            message: "This equipment observation has changed. Refresh and try again."
          }}, state}

      _ ->
        {:reply,
         {:error,
          %{
            code: "labels_unavailable",
            message:
              "Saved labels could not be read or written. Existing labels have not been replaced."
          }}, state}
    end
  end

  def handle_call({:begin_scan, _}, _, %{scan: scan} = state) when not is_nil(scan),
    do:
      {:reply,
       {:error,
        %{code: "operation_in_progress", message: "Wait for the current operation to finish."}},
       state}

  def handle_call({:begin_scan, scope}, {pid, _}, state) do
    ref = Process.monitor(pid)
    state = state |> stop_poll() |> set_scope(scope)
    {:reply, {:ok, ref}, publish(%{state | scan: ref, error: nil})}
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
    do:
      {:reply,
       {:error,
        %{
          code: "equipment_changed",
          message: "This equipment observation has changed. Refresh and try again."
        }}, state}

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, poll(state)}
  end

  def handle_info({:observing, pid, scope}, %{worker: %{task: %{pid: pid}}} = state) do
    state = %{state | worker: %{state.worker | observing: true}} |> set_scope(scope)
    {:noreply, state}
  end

  def handle_info({ref, {scope, result}}, %{worker: %{task: %{ref: ref}, timer: timer}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(timer)

    fault =
      case {scope, result} do
        {nil,
         {:error,
          %{
            code: "equipment_unconfigured",
            message: "Configure and save a static equipment address first."
          }}} ->
          false

        {nil, _} ->
          state.discovery_fault

        {_, {:ok, _}} ->
          false

        {_, {:error, _}} ->
          true
      end

    state =
      %{state | worker: nil, discovery_fault: fault} |> set_scope(scope) |> apply_entries(result)

    {:noreply, publish(state)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{scan: ref} = state),
    do:
      {:noreply,
       publish(%{
         state
         | scan: nil,
           error: %{
             code: "scan_interrupted",
             message: "The scan was interrupted. Network settings were not changed."
           }
       })}

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: %{task: %{ref: ref}}} = state),
    do: {:noreply, state |> poll_failed() |> publish()}

  def handle_info({:poll_timeout, ref}, %{worker: %{task: %{ref: ref}}} = state),
    do: {:noreply, state |> poll_failed() |> publish()}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: stop_poll(state)

  defp poll(%{worker: nil, scan: nil} = state) do
    owner = self()

    task =
      Task.async(fn ->
        case Subnet.from_status(Network.status()) do
          {:ok, scope} ->
            send(owner, {:observing, self(), scope})
            {scope, Linux.neighbors(scope)}

          {:error, reason} ->
            {nil, {:error, reason}}
        end
      end)

    timer = Process.send_after(self(), {:poll_timeout, task.ref}, state.effect_ms)
    %{state | worker: %{task: task, timer: timer, observing: false}}
  end

  defp poll(state), do: state

  defp poll_failed(state) do
    fault = if state.worker.observing, do: true, else: state.discovery_fault

    %{
      stop_poll(state)
      | error: %{
          code: "equipment_unavailable",
          message: "Equipment observations are unavailable."
        },
        discovery_fault: fault
    }
  end

  defp stop_poll(%{worker: nil} = state), do: state

  defp stop_poll(%{worker: worker} = state) do
    Task.shutdown(worker.task, :brutal_kill)
    Process.cancel_timer(worker.timer)
    %{state | worker: nil}
  end

  defp set_scope(%{scope: scope} = state, scope), do: state
  defp set_scope(state, scope), do: %{state | scope: scope, entries: %{}, last_scan: nil}

  defp apply_entries(state, {:error, %{code: _, message: _} = reason}),
    do: %{state | error: Error.safe(reason)}

  defp apply_entries(state, {:error, _}),
    do: %{
      state
      | error: Error.new("equipment_unavailable", "Equipment observations are unavailable.")
    }

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
      error: state.error && Error.safe(state.error),
      labels_error: state.labels_error && Error.safe(state.labels_error)
    }
  end

  defp sources, do: [{Observations.table(), Observations.workflow("equipment", inspect(self()))}]

  defp publish(state) do
    Alarms.report(:equipment_discovery_unavailable, state.name, state.discovery_fault)
    Observations.put(Observations.workflow("equipment", inspect(self())), public(state))
    state
  end

  @doc false
  def scan_available(_, %{available: false}) do
    {:error, %{code: "equipment_unavailable", message: "Equipment observations are unavailable."}}
  end

  def scan_available(status, _) do
    with :ok <- Network.Policy.available(status), {:ok, _} <- Subnet.active(status) do
      :ok
    end
  end

  def labels_available(%{available: false}) do
    {:error, %{code: "equipment_unavailable", message: "Equipment observations are unavailable."}}
  end

  def labels_available(%{labels_error: nil}) do
    :ok
  end

  def labels_available(_) do
    {:error,
     %{
       code: "labels_unavailable",
       message:
         "Saved labels could not be read or written. Existing labels have not been replaced."
     }}
  end
end

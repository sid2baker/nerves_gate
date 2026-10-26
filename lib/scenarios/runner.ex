defmodule Scenarios.Runner do
  @moduledoc """
  One admission owner for the multi-device simulator, shared by the site, CLI and CI.

  A scenario run, application install or manual control holds its devices. Runs on different devices proceed in
  parallel; a scenario with `devices: :all` holds every device for its run.
  """
  use GenServer
  alias Simulator.Faults
  alias Simulator.Network
  alias Scenarios.Qemu, as: Qemu

  @topic "scenarios"
  @event_limit 100
  @run_limit 20

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def run(device, selection \\ "all"), do: GenServer.call(__MODULE__, {:run, device, selection})
  def mode(device, mode), do: GenServer.call(__MODULE__, {:mode, device, mode})
  def manual(device, action), do: GenServer.call(__MODULE__, {:manual, device, action})
  # Application installs use the same exclusive admission and progress as scenarios.
  def install(device, path) do
    GenServer.call(__MODULE__, {:install, device, path})
  end

  def console(device), do: GenServer.call(__MODULE__, {:console, device})
  def lifecycle(action), do: GenServer.call(__MODULE__, {:lifecycle, action})

  def stop_session(id, request \\ self()),
    do: GenServer.call(__MODULE__, {:stop_session, id, request})

  def configure(change), do: GenServer.call(__MODULE__, {:configure, change})
  def subscribe, do: Phoenix.PubSub.subscribe(NervesGate.PubSub, @topic)
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(NervesGate.PubSub, @topic)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    simulator = Application.fetch_env!(:nerves_gate_workbench, :simulator_node)

    view = %{
      lifecycle: Simulator.subscribe(simulator),
      devices: %{},
      scenarios: Enum.map(Scenarios.all(), &Map.delete(&1, :module)),
      runs: [],
      blocked: false,
      events: []
    }

    {:ok,
     %{
       view: view,
       handles: %{},
       workers: %{},
       session_stopping: false,
       simulator: simulator,
       simulator_monitor: Process.monitor({Simulator, simulator})
     }}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

  def handle_call(_, _, %{session_stopping: true} = state),
    do:
      {:reply, {:error, "Simulator session is stopping; wait for mix dev.stop to finish."}, state}

  def handle_call({:console, device}, _, state) do
    with {:ok, id} <- device_id(state, device),
         false <- state.view.blocked,
         %{owner: :manual, manual_action: nil, blocked: false} <- state.view.devices[id] do
      vm = state.handles[id]
      {:reply, {:ok, %{address: vm.address, port: vm.forwards.usb}}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, "Acquire idle Manual control on the device page first."}, state}
    end
  end

  def handle_call({:install, device, path}, _, state) do
    with {:ok, id} <- device_id(state, device),
         :ok <- available(state, [id]),
         true <- is_binary(path) and Path.type(path) == :absolute and Path.extname(path) == ".ez" do
      owner = self()
      vm = state.handles[id]
      row = %{id: "install", name: "Install application"}

      start_run(state, id, [id], "install", [row], fn run_id ->
        install_application(owner, run_id, vm, path)
      end)
    else
      false -> {:reply, {:error, "Expected an absolute path to an .ez package"}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:stop_session, id, request}, _, state) when is_pid(request) do
    owner = Process.whereis(:nerves_gate_workbench_session)

    cond do
      map_size(state.workers) > 0 ->
        {:reply,
         {:error, "Finish scenario runs and release manual control before stopping the session."},
         state}

      state.view.lifecycle.status in [:starting, :stopping] ->
        {:reply,
         {:error,
          "Wait for the device lifecycle operation to finish before stopping the session."},
         state}

      not is_binary(id) or id != System.get_env("WORKBENCH_SESSION_ID") ->
        {:reply, {:error, "Session identity changed. Inspect mix dev.status."}, state}

      not is_pid(owner) or System.get_env("WORKBENCH_CI") == "true" ->
        {:reply,
         {:error, "This session cannot be stopped through the API. Use its original terminal."},
         state}

      true ->
        # Serialize with admission: no new command can race shutdown acceptance.
        send(owner, {:stop_session, request})

        lifecycle = %{
          state.view.lifecycle
          | status: :stopping,
            phase: "Stopping simulator session"
        }

        state = Map.put(state, :session_stopping, true)
        {:reply, :ok, publish(%{state | view: %{state.view | lifecycle: lifecycle}})}
    end
  end

  def handle_call({kind, _}, _, state)
      when kind in [:lifecycle, :configure] and map_size(state.workers) > 0,
      do: {:reply, {:error, "Finish the current operations first."}, state}

  def handle_call({:lifecycle, action}, _, state) do
    with true <- lifecycle_allowed?(action, state.view),
         :ok <- Simulator.lifecycle(state.simulator, action) do
      # Close admission immediately, before the asynchronous progress arrives.
      status = if action == "start", do: :starting, else: :stopping
      view = %{state.view | lifecycle: %{state.view.lifecycle | status: status}, devices: %{}}
      {:reply, :ok, publish(%{state | view: view, handles: %{}})}
    else
      false ->
        {:reply,
         {:error,
          "Lifecycle action unavailable. Release manual control or Reset after a failure."},
         state}

      error ->
        {:reply, error, state}
    end
  catch
    :exit, _ -> {:reply, {:error, "Simulator unavailable; restart mix dev."}, state}
  end

  def handle_call({:configure, change}, _, state) do
    {:reply, Simulator.configure(state.simulator, change), state}
  catch
    :exit, _ -> {:reply, {:error, "Simulator unavailable; restart mix dev."}, state}
  end

  def handle_call({:run, device, selection}, _, state) do
    scenarios = Scenarios.select(selection)

    with {:ok, id} <- device_id(state, device),
         [_ | _] <- scenarios,
         held =
           (if Enum.any?(scenarios, & &1.all) do
              Map.keys(state.handles)
            else
              [id]
            end),
         :ok <- available(state, held) do
      owner = self()

      devices =
        Map.new(state.handles, fn {id, vm} -> {id, Map.put(vm, :fixture, {:qemu, vm})} end)

      context = %{device: devices[id], devices: devices}

      start_run(state, id, held, selection, scenarios, fn run_id ->
        execute(owner, run_id, context, scenarios)
      end)
    else
      [] -> {:reply, {:error, "Unknown scenario"}, state}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:mode, device, "manual"}, _, state) do
    with {:ok, id} <- device_id(state, device), :ok <- available(state, [id]) do
      owner = self()
      vm = state.handles[id]

      {pid, ref} =
        :erlang.spawn_opt(
          fn ->
            report_to(owner)
            Faults.execute(owner, vm)
          end,
          [:link, :monitor]
        )

      worker = %{ref: ref, run: nil, devices: [id], timer: nil, completed: false}

      view =
        state.view
        |> hold([id], :manual)
        |> update_device(id, &%{&1 | manual_action: "acquire"})
        |> event("#{id}: manual control requested")

      state = %{state | view: view, workers: Map.put(state.workers, pid, worker)}
      {:reply, :ok, state |> arm_manual_timeout(pid) |> publish()}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:mode, device, "scenarios"}, _, state) do
    case device_id(state, device) do
      {:ok, id} ->
        case state.view.devices[id] do
          %{owner: :manual, manual_action: nil} ->
            {:reply, :ok, start_manual(state, id, "release")}

          %{owner: nil} ->
            {:reply, :ok, state}

          _ ->
            {:reply, {:error, "#{id}: finish the current operation first."}, state}
        end

      error ->
        {:reply, error, state}
    end
  end

  def handle_call({:mode, _, _}, _, state), do: {:reply, {:error, "Unknown mode"}, state}

  def handle_call({:manual, device, action}, _, state) do
    with {:ok, id} <- device_id(state, device),
         %{owner: :manual, manual_action: nil} <- state.view.devices[id],
         true <- action in Faults.actions() do
      {:reply, :ok, start_manual(state, id, action)}
    else
      false -> {:reply, {:error, "Unknown manual action"}, state}
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, "Manual control is required and must be idle."}, state}
    end
  end

  @impl true
  def handle_info({:simulator, %{status: :ready} = lifecycle}, state) do
    handles = Simulator.devices(state.simulator)
    devices = Map.new(handles, fn {id, vm} -> {id, device_view(vm)} end)
    view = %{state.view | devices: devices}
    {:noreply, lifecycle_progress(%{state | view: view, handles: handles}, lifecycle)}
  end

  def handle_info({:simulator, lifecycle}, state) do
    interrupted = state.workers != %{}
    state = Enum.reduce(Map.keys(state.workers), state, &interrupt(&2, &1))
    cleared = lifecycle.status == :stopped and not lifecycle.reset_required

    blocked =
      not cleared and
        (state.view.blocked or interrupted or lifecycle.status in [:failed, :unavailable])

    view = %{state.view | devices: %{}, blocked: blocked}
    {:noreply, lifecycle_progress(%{state | view: view, handles: %{}}, lifecycle)}
  end

  def handle_info({:progress, run_id, scenario, result}, state) do
    case worker_for(state, run_id) do
      {pid, worker} ->
        cancel_timer(worker)

        timeout = if scenario == "install", do: 600_000, else: 900_000

        timer =
          if result.status == :running,
            do: Process.send_after(self(), {:timeout, run_id, scenario}, timeout)

        view =
          state.view
          |> update_run(run_id, fn run ->
            %{run | rows: update_row(run.rows, scenario, &Map.merge(&1, result))}
          end)
          |> event("#{run_label(state.view, run_id)} · #{scenario}: #{result.status}")

        workers = Map.put(state.workers, pid, %{worker | timer: timer})
        {:noreply, publish(%{state | view: view, workers: workers})}

      nil ->
        {:noreply, state}
    end
  end

  def handle_info({:scenario_failed, run_id, scenario, detail}, state) do
    view =
      update_run(state.view, run_id, fn run ->
        %{run | rows: update_row(run.rows, scenario, &%{&1 | detail: detail})}
      end)

    {:noreply, publish(%{state | view: view})}
  end

  def handle_info({:phase, run_id, phase}, state) do
    view =
      state.view
      |> update_run(run_id, &%{&1 | phase: phase})
      |> event("#{run_label(state.view, run_id)} · #{phase}")

    {:noreply, publish(%{state | view: view})}
  end

  def handle_info({:fault, pid, device, key, label}, state) do
    faults = holds?(state, pid, device) && state.view.devices[device].faults

    if faults && Map.get(faults, key) != label do
      updated = if label, do: Map.put(faults, key, label), else: Map.delete(faults, key)
      message = if label, do: "injected #{label}", else: "cleared #{faults[key]}"

      view =
        state.view
        |> update_device(device, &%{&1 | faults: updated})
        |> event("#{device}: #{message}")

      {:noreply, publish(%{state | view: view})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:topology, pid, device, topology}, state) do
    if holds?(state, pid, device) do
      view =
        state.view
        |> update_device(device, &%{&1 | topology: topology})
        |> event("#{device}: LAN1 → #{topology.lan1}, LAN2 → #{topology.lan2}")

      {:noreply, publish(%{state | view: view})}
    else
      {:noreply, state}
    end
  end

  def handle_info({:manual_ready, pid}, state),
    do: {:noreply, manual_idle(state, pid, "manual control ready")}

  def handle_info({:manual_done, pid, action}, state),
    do: {:noreply, manual_idle(state, pid, "completed #{manual_label(action)}")}

  def handle_info({:manual_released, pid}, state), do: {:noreply, complete(state, pid)}

  def handle_info({:finished, run_id}, state) do
    case worker_for(state, run_id) do
      {pid, _} -> {:noreply, complete(state, pid)}
      nil -> {:noreply, state}
    end
  end

  def handle_info({:timeout, timer, {:manual_timeout, pid}}, state) do
    if match?(%{timer: ^timer}, state.workers[pid]), do: Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:timeout, run_id, scenario}, state) do
    with {pid, _} <- worker_for(state, run_id),
         %{rows: rows} <- Enum.find(state.view.runs, &(&1.id == run_id)),
         true <- Enum.any?(rows, &(&1.id == scenario and &1.status == :running)),
         do: Process.exit(pid, :kill)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{simulator_monitor: ref} = state) do
    state = Enum.reduce(Map.keys(state.workers), state, &interrupt(&2, &1))

    lifecycle = %{
      state.view.lifecycle
      | status: :unavailable,
        phase: "Simulator unavailable. Restart mix dev."
    }

    view =
      %{state.view | lifecycle: lifecycle, devices: %{}, blocked: true}
      |> event("Simulator stopped; device control is unavailable. Restart mix dev.")

    {:noreply, publish(%{state | view: view, handles: %{}})}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, state) do
    case state.workers[pid] do
      %{ref: ^ref} = worker ->
        cancel_timer(worker)

        uncertain =
          reason != :normal or not worker.completed or
            Enum.any?(worker.devices, &(not clean?(state.view.devices[&1])))

        view = finish(state.view, worker, uncertain)
        {:noreply, publish(%{state | view: view, workers: Map.delete(state.workers, pid)})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: for({pid, _} <- state.workers, do: Process.exit(pid, :kill))

  defp start_run(state, id, held, selection, scenarios, execute) do
    run_id = System.unique_integer([:positive, :monotonic])
    {pid, ref} = :erlang.spawn_opt(fn -> execute.(run_id) end, [:link, :monitor])

    rows =
      for scenario <- scenarios,
          do: %{
            id: scenario.id,
            name: scenario.name,
            status: :waiting,
            detail: "",
            milliseconds: nil
          }

    run = %{
      id: run_id,
      device: id,
      devices: Enum.sort(held),
      selection: selection,
      status: :running,
      phase: "Preparing",
      rows: rows
    }

    view =
      %{state.view | runs: keep_runs([run | state.view.runs])}
      |> hold(held, run_id)
      |> update_device(id, &%{&1 | run: run_id})
      |> event("#{id}: run ##{run_id} started: #{selection}")

    worker = %{ref: ref, run: run_id, devices: held, timer: nil, completed: false}
    state = %{state | view: view, workers: Map.put(state.workers, pid, worker)}
    {:reply, {:ok, run_id}, publish(state)}
  end

  defp install_application(owner, run_id, vm, path) do
    send(owner, {:progress, run_id, "install", %{status: :running}})
    send(owner, {:phase, run_id, "Installing application"})
    started = System.monotonic_time(:millisecond)

    result =
      case Scenarios.Apps.install(vm, path) do
        {:ok, installed} -> %{status: :passed, detail: "Running #{installed}"}
        {:error, _} -> %{status: :failed, detail: "Device rejected the application package"}
      end

    result = Map.put(result, :milliseconds, System.monotonic_time(:millisecond) - started)
    send(owner, {:progress, run_id, "install", result})
    send(owner, {:finished, run_id})
  catch
    # A disconnected device or timed-out lifecycle call can still be running.
    # Preserve the reservation until this worker exits, then block the device.
    _, _ -> exit(:application_install_uncertain)
  end

  defp device_view(vm) do
    topology = Qemu.topology(vm)

    %{
      id: vm.id,
      node: vm.node,
      address: vm.address,
      ui: Qemu.ui_url(vm),
      # The configured wiring the device booted with; scenarios use the baseline.
      wiring: topology,
      topology: topology,
      owner: nil,
      manual_action: nil,
      blocked: false,
      faults: %{},
      run: nil
    }
  end

  defp device_id(state, device) do
    case Enum.find(Map.keys(state.handles), &(Atom.to_string(&1) == to_string(device))) do
      nil when state.handles == %{} -> {:error, "Start the configured devices first."}
      nil -> {:error, "Unknown device #{device}"}
      id -> {:ok, id}
    end
  end

  defp available(state, ids) do
    Enum.find_value(ids, :ok, fn id ->
      case state.view.devices[id] do
        %{blocked: true} -> {:error, "#{id}: control uncertain. Reset the devices."}
        %{owner: :manual} -> {:error, "#{id}: manual control is held. Switch to Scenarios."}
        %{owner: nil} -> nil
        %{owner: run} -> {:error, "#{id}: run ##{run} is in progress."}
      end
    end)
  end

  defp clean?(device),
    do: device.faults == %{} and device.topology in [Network.baseline(), device.wiring]

  defp holds?(state, pid, device) do
    case state.workers[pid] do
      %{devices: devices} -> device in devices
      nil -> false
    end
  end

  defp hold(view, ids, owner),
    do: Enum.reduce(ids, view, &update_device(&2, &1, fn device -> %{device | owner: owner} end))

  defp update_device(view, id, fun),
    do: %{view | devices: Map.update!(view.devices, id, fun)}

  defp update_run(view, id, fun),
    do: %{view | runs: Enum.map(view.runs, &if(&1.id == id, do: fun.(&1), else: &1))}

  # Never evict an active run, even when more than 20 devices run concurrently.
  defp keep_runs(runs) do
    {active, finished} = Enum.split_with(runs, &(&1.status == :running))
    Enum.sort_by(active ++ Enum.take(finished, @run_limit), & &1.id, :desc)
  end

  defp update_row(rows, id, fun), do: Enum.map(rows, &if(&1.id == id, do: fun.(&1), else: &1))

  defp run_label(view, run_id) do
    case Enum.find(view.runs, &(&1.id == run_id)) do
      %{device: device} -> "#{device} ##{run_id}"
      nil -> "##{run_id}"
    end
  end

  defp worker_for(state, run_id), do: Enum.find(state.workers, fn {_, w} -> w.run == run_id end)

  defp complete(state, pid) do
    case state.workers[pid] do
      nil -> state
      worker -> %{state | workers: Map.put(state.workers, pid, %{worker | completed: true})}
    end
  end

  defp interrupt(state, pid) do
    worker = state.workers[pid]
    cancel_timer(worker)
    Process.demonitor(worker.ref, [:flush])
    Process.unlink(pid)
    Process.exit(pid, :kill)
    %{state | view: finish(state.view, worker, true), workers: Map.delete(state.workers, pid)}
  end

  defp lifecycle_allowed?("start", %{
         blocked: false,
         lifecycle: %{status: :stopped, reset_required: false}
       }),
       do: true

  defp lifecycle_allowed?("stop", %{blocked: false, lifecycle: %{status: :ready}}), do: true
  defp lifecycle_allowed?("stop", %{lifecycle: %{status: :starting}}), do: true

  defp lifecycle_allowed?("reset", %{lifecycle: %{status: status}})
       when status in [:stopped, :ready, :failed],
       do: true

  defp lifecycle_allowed?(_, _), do: false

  defp lifecycle_progress(state, lifecycle) do
    view = %{state.view | lifecycle: lifecycle}

    view =
      if state.view.lifecycle.phase != lifecycle.phase,
        do: event(view, lifecycle.phase),
        else: view

    publish(%{state | view: view})
  end

  defp start_manual(state, id, action) do
    {pid, _} = Enum.find(state.workers, fn {_, w} -> w.run == nil and w.devices == [id] end)
    send(pid, {:manual_action, action})

    view =
      state.view
      |> update_device(id, &%{&1 | manual_action: action})
      |> event("#{id}: requested #{manual_label(action)}")

    %{state | view: view} |> arm_manual_timeout(pid) |> publish()
  end

  defp arm_manual_timeout(state, pid) do
    worker = state.workers[pid]
    cancel_timer(worker)
    timer = :erlang.start_timer(15_000, self(), {:manual_timeout, pid})
    %{state | workers: Map.put(state.workers, pid, %{worker | timer: timer})}
  end

  defp manual_idle(state, pid, message) do
    case state.workers[pid] do
      %{run: nil, devices: [id]} = worker ->
        cancel_timer(worker)

        view =
          state.view
          |> update_device(id, &%{&1 | manual_action: nil})
          |> event("#{id}: #{message}")

        workers = Map.put(state.workers, pid, %{worker | timer: nil})
        publish(%{state | view: view, workers: workers})

      _ ->
        state
    end
  end

  defp manual_label("acquire"), do: "Take manual control"
  defp manual_label("clear"), do: "Clear all faults (keep disk and settings)"
  defp manual_label("release"), do: "Clear faults and release manual control"

  defp manual_label(action) do
    Enum.find_value(Faults.controls(), fn control ->
      if choice = List.keyfind(control.choices, action, 0),
        do: "#{control.name}: #{elem(choice, 1)}"
    end)
  end

  # Release the worker's devices. An uncertain outcome blocks them until Reset.
  defp finish(view, worker, uncertain) do
    devices =
      Map.new(view.devices, fn {id, device} ->
        if id in worker.devices,
          do:
            {id, %{device | owner: nil, manual_action: nil, blocked: device.blocked or uncertain}},
          else: {id, device}
      end)

    view = %{view | devices: devices, blocked: view.blocked or uncertain}

    if worker.run,
      do: finish_run(view, worker.run, uncertain),
      else: finish_manual(view, worker, uncertain)
  end

  defp finish_manual(view, %{devices: [id]}, false),
    do: event(view, "#{id}: manual control released; disk and settings preserved")

  defp finish_manual(view, %{devices: [id]}, true),
    do: event(view, "#{id}: manual control or cleanup failed. Fault state is uncertain; Reset.")

  defp finish_run(view, run_id, uncertain) do
    view
    |> update_run(run_id, fn run ->
      rows = if uncertain, do: Enum.map(run.rows, &stopped/1), else: run.rows

      status = if uncertain, do: :failed, else: Scenarios.result(rows)

      phase = if uncertain, do: "Control state uncertain; Reset the devices", else: "Finished"
      %{run | rows: rows, status: status, phase: phase}
    end)
    |> then(fn view ->
      run = Enum.find(view.runs, &(&1.id == run_id))
      view = event(view, "#{run_label(view, run_id)} #{run.status}")
      %{view | runs: keep_runs(view.runs)}
    end)
  end

  defp stopped(%{status: status} = row) when status in [:waiting, :running] do
    detail =
      if row.detail == "", do: "Runner stopped; inspect QEMU diagnostics.", else: row.detail

    %{row | status: :failed, detail: detail}
  end

  defp stopped(row), do: row

  defp cancel_timer(%{timer: nil}), do: :ok
  defp cancel_timer(%{timer: timer}), do: Process.cancel_timer(timer)

  defp event(view, message) do
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      at: DateTime.to_iso8601(DateTime.utc_now()),
      message: message
    }

    %{view | events: Enum.take(view.events ++ [entry], -@event_limit)}
  end

  defp publish(state) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, @topic, {:scenarios, state.view})
    state
  end

  defp report_to(owner) do
    pid = self()

    Process.put(:qemu_fault, fn device, key, label ->
      send(owner, {:fault, pid, device, key, label})
    end)

    Process.put(:qemu_topology, fn device, topology ->
      send(owner, {:topology, pid, device, topology})
    end)
  end

  defp execute(owner, run_id, context, scenarios) do
    vm = context.device
    report_to(owner)
    report = fn phase -> send(owner, {:phase, run_id, phase}) end
    Process.put(:qemu_report, report)
    Process.put(:scenario_report, report)

    for scenario <- scenarios do
      send(owner, {:progress, run_id, scenario.id, %{status: :running}})
      start = System.monotonic_time(:millisecond)
      affected = if scenario.all, do: Map.values(context.devices), else: [vm]

      result = run_scenario(scenario, context, affected)

      if result.status == :failed do
        # Keep the original failure and collect evidence while the fault is still present.
        # Leave the scenario timer armed until cleanup and disk replacement finish.
        send(owner, {:scenario_failed, run_id, scenario.id, result.detail})
        Enum.each(affected, &Scenarios.Recovery.capture_failure/1)
      end

      # An uncertain control outcome forbids further commands. Cleanup failures stop
      # the worker and block its devices; neither can overwrite the original failure.
      if Process.get(:simulator_control_failed), do: exit(:simulator_control_failed)
      if result.status != :skipped, do: Qemu.cleanup()

      if result.status != :skipped and (scenario.fresh_disk or result.status == :failed) do
        send(
          owner,
          {:phase, run_id,
           "Replacing disposable disks after #{scenario.id}; enrollment is erased"}
        )

        fresh_devices(affected, vm, [])
        Qemu.cleanup()
      end

      result = Map.put(result, :milliseconds, System.monotonic_time(:millisecond) - start)
      send(owner, {:progress, run_id, scenario.id, result})
    end

    send(owner, {:finished, run_id})
  end

  defp run_scenario(scenario, context, affected) do
    Scenarios.run(scenario, context, fn ->
      if scenario.fresh_disk,
        do: fresh_devices(affected, context.device, Map.get(scenario.module.spec(), :boot, [])),
        else: baseline(context.device)

      :ok
    end)
  catch
    :exit, :simulator_control_failed -> exit(:simulator_control_failed)
    kind, reason -> %{status: :failed, detail: Exception.format(kind, reason, __STACKTRACE__)}
  end

  defp fresh_devices(devices, primary, options) do
    for device <- devices, do: Qemu.fresh(device, options)
    :ok = Qemu.network(primary, Network.defaults())
  end

  defp baseline(vm) do
    Qemu.resume(vm)
    Qemu.insert_lan1(vm)
    :ok = Qemu.network(vm, Network.defaults())
    status = Scenarios.Device.await(vm, "Waiting for device", & &1)

    if status.network.pending,
      do: Scenarios.Device.rpc(vm, NervesGate.Network, :cancel, [status.network.pending.id])

    Scenarios.Device.save(vm, Scenarios.Device.settings("eth0"))
    Scenarios.Device.await(vm, "Baseline: eth0 address", &Scenarios.Device.addressed?/1)
  end
end

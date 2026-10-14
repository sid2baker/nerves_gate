defmodule NervesGate.QemuTests do
  @moduledoc "One test bench and one owned QEMU device, shared by the page, CLI and CI."
  use GenServer
  alias NervesGate.ManualFaults
  alias NervesGate.TestQemu, as: Qemu

  @topic "qemu-tests"
  @event_limit 100

  defp scenarios do
    Path.wildcard("test/scenarios/*.ex")
    |> Enum.map(fn path ->
      id = Path.basename(path, ".ex")
      {id, Module.concat(NervesGate.Scenarios, Macro.camelize(id))}
    end)
  end

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def run(selection \\ "all"), do: GenServer.call(__MODULE__, {:run, selection})
  def mode(mode), do: GenServer.call(__MODULE__, {:mode, mode})
  def manual(action), do: GenServer.call(__MODULE__, {:manual, action})
  def subscribe, do: Phoenix.PubSub.subscribe(NervesGate.PubSub, @topic)
  def unsubscribe, do: Phoenix.PubSub.unsubscribe(NervesGate.PubSub, @topic)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    rows =
      Enum.map(scenarios(), fn {id, module} ->
        %{
          id: id,
          name: module.name(),
          fresh_disk: function_exported?(module, :boot_options, 0),
          status: :waiting,
          detail: "",
          milliseconds: nil
        }
      end)

    view = %{
      id: nil,
      status: :idle,
      rows: rows,
      phase: "Ready",
      mode: :scenarios,
      manual_action: nil,
      blocked: false,
      faults: %{},
      events: []
    }

    {:ok,
     %{
       view: view,
       vm: Application.get_env(:nerves_gate, :qemu_vm),
       worker: nil,
       timer: nil,
       completed: false
     }}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

  def handle_call(_, _, %{view: %{blocked: true}} = state),
    do:
      {:reply, {:error, "Control state is uncertain. Restart mix dev.qemu before continuing."},
       state}

  def handle_call(_, _, %{vm: nil} = state),
    do:
      {:reply, {:error, "Start mix dev.qemu. Tests never attach to an arbitrary device."}, state}

  def handle_call({:run, _}, _, %{view: %{mode: :manual}} = state),
    do:
      {:reply,
       {:error, "Manual control is held. Switch to Scenarios to clear faults and release it."},
       state}

  def handle_call({:run, _}, _, %{worker: worker} = state) when not is_nil(worker),
    do: {:reply, {:error, "A run is already in progress."}, state}

  def handle_call({:run, selection}, _, state) do
    scenarios = Enum.filter(scenarios(), fn {id, _} -> selection in ["all", id] end)

    if scenarios == [] do
      {:reply, {:error, "Unknown scenario"}, state}
    else
      owner = self()
      id = System.unique_integer([:positive, :monotonic])

      worker =
        :erlang.spawn_opt(fn -> execute(owner, id, state.vm, scenarios) end, [:link, :monitor])

      rows = prepare_rows(state.view.rows, selection)

      view =
        %{state.view | id: id, rows: rows, status: :running, phase: "Preparing"}
        |> event("Run ##{id} started: #{selection}")

      {:reply, {:ok, id}, publish(%{state | worker: worker, view: view, completed: false})}
    end
  end

  def handle_call({:mode, "manual"}, _, %{worker: nil} = state) do
    owner = self()

    worker =
      :erlang.spawn_opt(
        fn ->
          report_to(owner)
          ManualFaults.execute(owner, state.vm)
        end,
        [:link, :monitor]
      )

    view =
      %{state.view | mode: :manual, manual_action: "acquire", phase: "Taking manual control"}
      |> event("Manual control requested")

    state = %{state | worker: worker, view: view, completed: false}
    {:reply, :ok, state |> arm_manual_timeout() |> publish()}
  end

  def handle_call({:mode, "scenarios"}, _, %{view: %{mode: :manual, manual_action: nil}} = state),
    do: {:reply, :ok, start_manual(state, "release")}

  def handle_call({:mode, "scenarios"}, _, %{worker: nil} = state),
    do: {:reply, :ok, state}

  def handle_call({:mode, _}, _, state),
    do: {:reply, {:error, "Finish the current operation before changing control mode."}, state}

  def handle_call({:manual, action}, _, %{view: %{mode: :manual, manual_action: nil}} = state) do
    if action in ManualFaults.actions() do
      {:reply, :ok, start_manual(state, action)}
    else
      {:reply, {:error, "Unknown manual action"}, state}
    end
  end

  def handle_call({:manual, _}, _, state),
    do:
      {:reply, {:error, "Manual control is required and no other operation may be running."},
       state}

  @impl true
  def handle_info({:progress, id, scenario, result}, %{view: %{id: id}} = state) do
    cancel_timer(state)

    timer =
      if result.status == :running,
        do: Process.send_after(self(), {:timeout, id, scenario}, 300_000)

    rows =
      Enum.map(state.view.rows, fn row ->
        if row.id == scenario, do: Map.merge(row, result), else: row
      end)

    view = %{state.view | rows: rows} |> event("#{scenario}: #{result.status}")
    {:noreply, publish(%{state | view: view, timer: timer})}
  end

  def handle_info({:phase, id, phase}, %{view: %{id: id}} = state) do
    view = %{state.view | phase: phase} |> event(phase)
    {:noreply, publish(%{state | view: view})}
  end

  def handle_info({:fault, pid, key, label}, %{worker: {pid, _}} = state) do
    faults = state.view.faults

    view =
      if Map.get(faults, key) == label do
        state.view
      else
        updated = if label, do: Map.put(faults, key, label), else: Map.delete(faults, key)
        message = if label, do: "Injected: #{label}", else: "Cleared: #{faults[key]}"
        %{state.view | faults: updated} |> event(message)
      end

    {:noreply, publish(%{state | view: view})}
  end

  def handle_info({:manual_ready, pid}, %{worker: {pid, _}} = state),
    do: {:noreply, manual_idle(state, "Manual control ready")}

  def handle_info({:manual_done, pid, action}, %{worker: {pid, _}} = state),
    do: {:noreply, manual_idle(state, "Completed: #{manual_label(action)}")}

  def handle_info({:manual_released, pid}, %{worker: {pid, _}} = state),
    do: {:noreply, %{state | completed: true}}

  def handle_info({:finished, id, vm}, %{view: %{id: id}} = state),
    do: {:noreply, %{state | vm: vm, completed: true}}

  def handle_info(
        {:timeout, timer, {:manual_timeout, ref}},
        %{worker: {pid, ref}, timer: timer} = state
      ) do
    Process.exit(pid, :kill)
    {:noreply, state}
  end

  def handle_info({:timeout, id, scenario}, %{view: %{id: id}, worker: {pid, _}} = state) do
    if Enum.any?(state.view.rows, &(&1.id == scenario && &1.status == :running)),
      do: Process.exit(pid, :kill)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{worker: {pid, ref}} = state) do
    cancel_timer(state)
    blocked = reason != :normal or not state.completed or state.view.faults != %{}
    view = finish(state.view, blocked)
    {:noreply, publish(%{state | worker: nil, timer: nil, view: view})}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{worker: {pid, _}}), do: Process.exit(pid, :kill)
  def terminate(_, _), do: :ok

  defp start_manual(%{worker: {pid, _}} = state, action) do
    send(pid, {:manual_action, action})
    label = manual_label(action)
    view = %{state.view | manual_action: action, phase: label} |> event("Requested: #{label}")
    %{state | view: view} |> arm_manual_timeout() |> publish()
  end

  defp arm_manual_timeout(%{worker: {_, ref}} = state) do
    cancel_timer(state)
    %{state | timer: :erlang.start_timer(15_000, self(), {:manual_timeout, ref})}
  end

  defp manual_idle(state, message) do
    cancel_timer(state)
    view = %{state.view | manual_action: nil, phase: "Manual control ready"} |> event(message)
    publish(%{state | view: view, timer: nil})
  end

  defp manual_label("acquire"), do: "Take manual control"
  defp manual_label("clear"), do: "Clear all faults (keep disk and settings)"
  defp manual_label("release"), do: "Clear faults and release manual control"

  defp manual_label(action) do
    Enum.find_value(ManualFaults.controls(), fn control ->
      if choice = List.keyfind(control.choices, action, 0),
        do: "#{control.name}: #{elem(choice, 1)}"
    end)
  end

  defp finish(view, true) do
    rows =
      Enum.map(view.rows, fn row ->
        if row.status in [:waiting, :running] and view.mode == :scenarios,
          do: %{row | status: :failed, detail: "Runner stopped; inspect QEMU diagnostics."},
          else: row
      end)

    %{
      view
      | blocked: true,
        status: :failed,
        rows: rows,
        manual_action: nil,
        phase: "Control state uncertain"
    }
    |> event("Worker or cleanup failed. Fault state is uncertain; restart mix dev.qemu.")
  end

  defp finish(%{mode: :manual} = view, false) do
    %{view | mode: :scenarios, manual_action: nil, phase: "Ready"}
    |> event("Manual control released; disk and settings preserved")
  end

  defp finish(view, false) do
    status =
      if Enum.all?(view.rows, &(&1.status in [:passed, :skipped])), do: :passed, else: :failed

    %{view | status: status, phase: "Finished"} |> event("Run ##{view.id} #{status}")
  end

  defp cancel_timer(%{timer: nil}), do: :ok
  defp cancel_timer(%{timer: timer}), do: Process.cancel_timer(timer)

  defp prepare_rows(rows, selection) do
    Enum.map(rows, fn row ->
      status = if selection in ["all", row.id], do: :waiting, else: :skipped
      %{row | status: status, detail: "", milliseconds: nil}
    end)
  end

  defp event(view, message) do
    entry = %{
      id: System.unique_integer([:positive, :monotonic]),
      at: DateTime.to_iso8601(DateTime.utc_now()),
      message: message
    }

    %{view | events: Enum.take(view.events ++ [entry], -@event_limit)}
  end

  defp publish(state) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, @topic, {:qemu_tests, state.view})
    state
  end

  defp report_to(owner) do
    pid = self()
    Process.put(:qemu_fault, fn key, label -> send(owner, {:fault, pid, key, label}) end)
  end

  defp execute(owner, run_id, vm, scenarios) do
    Qemu.adopt(vm)
    report_to(owner)
    Process.put(:qemu_report, fn phase -> send(owner, {:phase, run_id, phase}) end)

    for {id, module} <- scenarios do
      send(owner, {:progress, run_id, id, %{status: :running}})
      start = System.monotonic_time(:millisecond)
      reset? = function_exported?(module, :boot_options, 0)

      result =
        try do
          vm =
            if reset?, do: Qemu.fresh(Qemu.current(), module.boot_options()), else: Qemu.current()

          unless reset?, do: baseline(vm)
          module.run(vm)
          %{status: :passed, detail: "OK"}
        rescue
          error -> %{status: :failed, detail: Exception.format(:error, error, __STACKTRACE__)}
        catch
          kind, reason ->
            %{status: :failed, detail: Exception.format(kind, reason, __STACKTRACE__)}
        after
          # A cleanup failure stops the worker and blocks further runs, rather than hiding a fault.
          Qemu.cleanup()
        end

      if reset? or result.status == :failed do
        send(
          owner,
          {:phase, run_id, "Replacing disposable disk after #{id}; enrollment is erased"}
        )

        Qemu.fresh(Qemu.current())
      end

      result = Map.put(result, :milliseconds, System.monotonic_time(:millisecond) - start)
      send(owner, {:progress, run_id, id, result})
    end

    if Qemu.current().socket != vm.socket do
      :ok = :gen_tcp.controlling_process(Qemu.current().socket, owner)
    end

    send(owner, {:finished, run_id, Qemu.current()})
  end

  defp baseline(vm) do
    Qemu.resume(vm)
    Qemu.plug_wan(vm)
    Qemu.reconnect_wan(vm)
    Qemu.reconnect_equipment(vm)
    status = Qemu.await(vm, "Waiting for device", & &1)
    if status.network.pending, do: Qemu.call(vm, :network_cancel, [status.network.pending.id])
    NervesGate.ScenarioHelpers.save(vm, NervesGate.ScenarioHelpers.settings("eth0"))
    Qemu.await(vm, "Baseline: eth0 address", &NervesGate.ScenarioHelpers.addressed?/1)
  end
end

defmodule NervesGate.QemuTests do
  @moduledoc "One runner and one QEMU device, shared by the page, CLI and CI."
  use GenServer
  alias NervesGate.TestQemu, as: Qemu

  @topic "qemu-tests"
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
  def subscribe, do: Phoenix.PubSub.subscribe(NervesGate.PubSub, @topic)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    rows =
      Enum.map(scenarios(), fn {id, module} ->
        %{id: id, name: module.name(), status: :waiting, detail: "", milliseconds: nil}
      end)

    view = %{id: nil, status: :idle, rows: rows, phase: "Ready", firmware: nil}

    {:ok,
     %{
       view: view,
       vm: Application.get_env(:nerves_gate, :qemu_vm),
       worker: nil,
       timer: nil,
       blocked: false
     }}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

  def handle_call({:run, _}, _, %{blocked: true} = state),
    do: {:reply, {:error, "Cleanup or runner failed. Restart mix dev.qemu."}, state}

  def handle_call({:run, _}, _, %{worker: worker} = state) when not is_nil(worker),
    do: {:reply, {:error, "A run is already in progress."}, state}

  def handle_call({:run, _}, _, %{vm: nil} = state),
    do:
      {:reply, {:error, "Start mix dev.qemu. Tests never attach to an arbitrary device."}, state}

  def handle_call({:run, selection}, _, state) do
    scenarios = Enum.filter(scenarios(), fn {id, _} -> selection in ["all", id] end)

    if scenarios == [] do
      {:reply, {:error, "Unknown scenario"}, state}
    else
      owner = self()
      id = System.unique_integer([:positive, :monotonic])
      worker = spawn_monitor(fn -> execute(owner, id, state.vm, scenarios) end)

      rows = prepare_rows(state.view.rows, selection)

      view = %{state.view | id: id, rows: rows, status: :running, phase: "Preparing"}
      broadcast(view)
      {:reply, {:ok, id}, %{state | worker: worker, view: view}}
    end
  end

  @impl true
  def handle_info({:progress, id, scenario, result}, %{view: %{id: id}} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    timer =
      if result.status == :running,
        do: Process.send_after(self(), {:timeout, id, scenario}, 300_000)

    rows =
      Enum.map(state.view.rows, fn row ->
        if row.id == scenario, do: Map.merge(row, result), else: row
      end)

    view = %{state.view | rows: rows}
    broadcast(view)
    {:noreply, %{state | view: view, timer: timer}}
  end

  def handle_info({:phase, id, phase}, %{view: %{id: id}} = state) do
    view = %{state.view | phase: phase}
    broadcast(view)
    {:noreply, %{state | view: view}}
  end

  def handle_info({:finished, id, vm}, %{view: %{id: id}} = state),
    do: {:noreply, %{state | vm: vm}}

  def handle_info({:timeout, id, scenario}, %{view: %{id: id}, worker: {pid, _}} = state) do
    if Enum.any?(state.view.rows, &(&1.id == scenario && &1.status == :running)),
      do: Process.exit(pid, :kill)

    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, pid, reason}, %{worker: {pid, ref}} = state) do
    if state.timer, do: Process.cancel_timer(state.timer)

    rows =
      Enum.map(state.view.rows, fn row ->
        if row.status in [:waiting, :running],
          do: %{row | status: :failed, detail: "Runner stopped: #{inspect(reason)}"},
          else: row
      end)

    status = if Enum.all?(rows, &(&1.status in [:passed, :skipped])), do: :passed, else: :failed
    view = %{state.view | rows: rows, status: status, phase: "Finished"}
    broadcast(view)
    {:noreply, %{state | worker: nil, timer: nil, blocked: reason != :normal, view: view}}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{worker: {pid, _}}), do: Process.exit(pid, :kill)
  def terminate(_, _), do: :ok

  defp prepare_rows(rows, selection) do
    Enum.map(rows, fn row ->
      status = if selection in ["all", row.id], do: :waiting, else: :skipped
      %{row | status: status, detail: "", milliseconds: nil}
    end)
  end

  defp broadcast(view),
    do: Phoenix.PubSub.broadcast(NervesGate.PubSub, @topic, {:qemu_tests, view})

  defp execute(owner, run_id, vm, scenarios) do
    Qemu.adopt(vm)
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

      if reset? or result.status == :failed, do: Qemu.fresh(Qemu.current())
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

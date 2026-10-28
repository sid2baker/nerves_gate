defmodule Workbench.AdmissionTest do
  use ExUnit.Case, async: false
  alias Scenarios.Runner
  alias Simulator.Network

  setup do
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    start_supervised!({Phoenix.PubSub, name: NervesGate.PubSub})
    :ok
  end

  # Exercise admission only: invalid local archives finish before any device RPC.
  # This is not a hardware backend and never launches QEMU or device services.
  test "an install reserves its device until the worker exits" do
    path = Path.join(System.tmp_dir!(), "absent-#{System.unique_integer([:positive])}.ez")
    from = {self(), make_ref()}
    {:reply, {:ok, run}, state} = Runner.handle_call({:install, :a, path}, from, state())
    assert state.view.devices.a.owner == run
    assert state.view.devices.b.owner == nil
    assert map_size(state.workers) == 1

    for request <- [
          {:install, :a, path},
          {:run, :a, "sdk"},
          {:mode, :a, "manual"},
          {:lifecycle, "stop"},
          {:lifecycle, "reset"},
          {:configure, {:put, "c", "lan1"}},
          {:stop_session, "anything", self()}
        ] do
      assert {:reply, {:error, _}, ^state} = Runner.handle_call(request, from, state)
    end

    [{pid, %{ref: ref}}] = Map.to_list(state.workers)
    assert_receive {:progress, ^run, "install", %{status: :running} = result}
    {:noreply, state} = Runner.handle_info({:progress, run, "install", result}, state)
    assert_receive {:phase, ^run, _}
    assert_receive {:progress, ^run, "install", %{status: :failed} = result}
    {:noreply, state} = Runner.handle_info({:progress, run, "install", result}, state)
    assert_receive {:finished, ^run}
    {:noreply, state} = Runner.handle_info({:finished, run}, state)
    assert state.view.devices.a.owner == run
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    {:noreply, state} = Runner.handle_info({:DOWN, ref, :process, pid, :normal}, state)
    assert state.view.devices.a.owner == nil
    refute state.view.devices.a.blocked
    assert state.workers == %{}
    assert [%{status: :failed}] = state.view.runs
  end

  test "manual ownership, blocked state and invalid paths exclude installation" do
    from = {self(), make_ref()}

    for state <- [
          put_in(state().view.devices.a.owner, :manual),
          put_in(state().view.devices.a.blocked, true)
        ] do
      assert {:reply, {:error, _}, ^state} =
               Runner.handle_call({:install, :a, "/tmp/app.ez"}, from, state)
    end

    for path <- [nil, "relative.ez", "/tmp/app.txt"] do
      state = state()

      assert {:reply, {:error, _}, ^state} =
               Runner.handle_call({:install, :a, path}, from, state)
    end
  end

  test "long jobs exclude lifecycle and shutdown until their worker exits" do
    pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    from = {self(), make_ref()}

    {:reply, :ok, held} =
      Runner.handle_call({:admit_job, pid, "install", "/tmp/app"}, from, state())

    assert held.job.pid == pid

    for request <- [
          {:lifecycle, "stop"},
          {:lifecycle, "reset"},
          {:configure, :anything},
          {:stop_session, "anything", self()},
          {:admit_job, self(), "test", nil}
        ] do
      assert {:reply, {:error, _}, ^held} = Runner.handle_call(request, from, held)
    end

    ref = held.job.ref
    send(pid, :finish)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    {:noreply, released} = Runner.handle_info({:DOWN, ref, :process, pid, :normal}, held)
    assert released.job == nil
  end

  test "session shutdown prevents admission of a new job" do
    state = %{state() | session_stopping: true}

    assert {:reply, {:error, _}, ^state} =
             Runner.handle_call({:admit_job, self(), "install", nil}, {self(), make_ref()}, state)
  end

  test "distributed CLI watchers receive snapshots and are removed on exit" do
    pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    from = {self(), make_ref()}
    initial = state()
    assert {:reply, {owner, view}, watched} = Runner.handle_call({:watch, pid}, from, initial)
    assert owner == self()
    assert view == initial.view
    ref = watched.watchers[pid]
    send(pid, :finish)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}

    assert {:noreply, released} =
             Runner.handle_info({:DOWN, ref, :process, pid, :normal}, watched)

    assert released.watchers == %{}
  end

  test "packaging reservation excludes other callers before install starts" do
    from = {self(), make_ref()}

    pid =
      spawn(fn ->
        receive do
          :finish -> :ok
        end
      end)

    {:reply, :ok, held} =
      Runner.handle_call(
        {:admit_job, pid, "install", %{device: :a, subject: "/tmp/app"}},
        from,
        state()
      )

    assert held.view.devices.a.owner == {:job, pid}

    for request <- [{:run, :a, "sdk"}, {:mode, :a, "manual"}, {:install, :a, "/tmp/app.ez"}] do
      assert {:reply, {:error, _}, ^held} = Runner.handle_call(request, from, held)
    end

    ref = held.job.ref
    send(pid, :finish)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
    {:noreply, released} = Runner.handle_info({:DOWN, ref, :process, pid, :normal}, held)
    assert released.view.devices.a.owner == nil
  end

  test "uncertain worker termination is distinct and blocks further control" do
    {:reply, {:ok, run}, state} =
      Runner.handle_call({:install, :a, "/tmp/absent.ez"}, {self(), make_ref()}, state())

    [{pid, %{ref: ref}}] = Map.to_list(state.workers)
    Process.unlink(pid)
    Process.exit(pid, :kill)
    {:noreply, state} = Runner.handle_info({:DOWN, ref, :process, pid, :killed}, state)

    assert [%{id: ^run, status: :uncertain, outcome: :uncertain, certainty: :unknown}] =
             state.view.runs

    assert state.view.devices.a.blocked

    assert {:reply, {:error, _}, ^state} =
             Runner.handle_call({:run, :a, "sdk"}, {self(), make_ref()}, state)
  end

  defp state do
    devices =
      for id <- [:a, :b], into: %{} do
        {id,
         %{
           id: id,
           owner: nil,
           blocked: false,
           run: nil,
           manual_action: nil,
           faults: %{},
           topology: Network.baseline(),
           wiring: Network.baseline()
         }}
      end

    %{
      session_stopping: false,
      job: nil,
      workers: %{},
      handles: %{a: %{id: :a}, b: %{id: :b}},
      view: %{
        devices: devices,
        runs: [],
        operations: [],
        events: [],
        blocked: false,
        lifecycle: %{status: :ready}
      }
    }
  end
end

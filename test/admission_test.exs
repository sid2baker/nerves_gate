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

  test "console details require idle manual ownership and expose no credentials" do
    from = {self(), make_ref()}
    state = state()
    assert {:reply, {:error, _}, ^state} = Runner.handle_call({:console, :a}, from, state)
    state = put_in(state.view.devices.a.owner, :manual)

    state =
      put_in(state.handles.a, %{address: "127.0.0.2", forwards: %{usb: 22}, secret: "private"})

    assert {:reply, {:ok, %{address: "127.0.0.2", port: 22}}, ^state} =
             Runner.handle_call({:console, :a}, from, state)

    for state <- [
          put_in(state.view.devices.a.blocked, true),
          put_in(state.view.devices.a.manual_action, "release"),
          put_in(state.view.blocked, true)
        ] do
      assert {:reply, {:error, _}, ^state} = Runner.handle_call({:console, :a}, from, state)
    end
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
      workers: %{},
      handles: %{a: %{id: :a}, b: %{id: :b}},
      view: %{
        devices: devices,
        runs: [],
        events: [],
        blocked: false,
        lifecycle: %{status: :ready}
      }
    }
  end
end

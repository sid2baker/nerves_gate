defmodule Workbench.OperationsTest do
  use ExUnit.Case, async: true

  test "busy and stopping admission rejects operations, lifecycle and session shutdown" do
    {:ok, idle} = Workbench.Operations.init(nil)
    from = {self(), make_ref()}

    for state <- [%{idle | task: %{ref: make_ref()}}, %{idle | stopping: true}] do
      for request <- [
            {:start, "firmware", nil, nil},
            {:start, "install", "sample", "gateway_a"},
            {:start, "device_info", "ec100.example.ts.net", nil},
            {:review_factory, %{}},
            {:confirm_factory, "token", "ERASE EC100 101", "true"},
            {:lifecycle, "start"},
            {:lifecycle, "reset"},
            {:stop_session, "session"}
          ] do
        assert {:reply, {:error, _}, ^state} =
                 Workbench.Operations.handle_call(request, from, state)
      end

      assert {:reply, view, ^state} = Workbench.Operations.handle_call(:snapshot, from, state)
      assert view == state.view
    end
  end

  test "factory and SSH confirmations cannot consume each other's reviews" do
    {:ok, idle} = Workbench.Operations.init(nil)
    from = {self(), make_ref()}

    assert {:reply, {:error, _}, ^idle} =
             Workbench.Operations.handle_call(
               {:confirm_factory, "id", "text", "true"},
               from,
               idle
             )

    ssh = %{idle | review: %{public: %{address: "ec100.local"}}}

    assert {:reply, {:error, _}, ^ssh} =
             Workbench.Operations.handle_call({:confirm_factory, "id", "text", "true"}, from, ssh)

    factory = %{
      idle
      | review: %{
          public: %{kind: :factory, token: "id", confirmation: "ERASE EC100 101"},
          expires: System.monotonic_time(:millisecond) + 60_000
        }
    }

    assert {:reply, {:error, _}, ^factory} =
             Workbench.Operations.handle_call(
               {:confirm_firmware, "id", "ec100.local"},
               from,
               factory
             )

    assert {:reply, {:error, _}, ^factory} =
             Workbench.Operations.handle_call(
               {:confirm_factory, "wrong-id", "ERASE EC100 101", "true"},
               from,
               factory
             )
  end

  @tag :tmp_dir
  test "factory expiry drops only the snapshot and never a retained backup", %{tmp_dir: root} do
    {:ok, idle} = Workbench.Operations.init(nil)
    dir = Path.join(root, "snapshot")
    backup = Path.join(root, "backup")
    File.mkdir!(dir)
    File.mkdir!(backup)
    plan = %{dir: dir, public: %{kind: :factory, token: "token", backup: backup}}
    state = %{idle | review: plan, view: %{idle.view | review: plan.public}}

    assert {:noreply, ^state} =
             Workbench.Operations.handle_info({:expire_review, "old-token"}, state)

    assert {:noreply, expired} =
             Workbench.Operations.handle_info({:expire_review, "token"}, state)

    assert expired.review == nil
    assert expired.view.review == nil
    assert expired.view.result =~ "MASKROM"
    refute File.exists?(dir)
    assert File.dir?(backup)
  end

  test "worker failure keeps recovery location and reports only a safe exit category" do
    for {reason, category} <- [
          {:epipe, "epipe"},
          {:killed, "killed"},
          {:shutdown, "shutdown"},
          {{:shutdown, "private reason"}, "shutdown"},
          {:normal, "normal exit without a result"},
          {{:timeout, "private command"}, "timeout"},
          {{:unexpected, "private reason"}, "unexpected termination"}
        ] do
      {:ok, idle} = Workbench.Operations.init(nil)
      ref = make_ref()
      recovery = %{backup: "/backups/owned-recovery"}
      view = %{idle.view | kind: "factory_provision", status: :running, recovery: recovery}
      state = %{idle | task: %{ref: ref}, view: view}

      assert {:noreply, failed} =
               Workbench.Operations.handle_info({:DOWN, ref, :process, self(), reason}, state)

      assert failed.task == nil
      assert failed.view.status == :failed
      assert failed.view.recovery == recovery
      assert failed.view.result =~ category
      assert failed.view.result =~ "outcome is unknown"
      assert failed.view.result =~ "Do not retry automatically"
      refute failed.view.result =~ "private"
    end
  end

  test "verified-flash phase survives reconnect timeout, exception and worker death" do
    {:ok, idle} = Workbench.Operations.init(nil)
    ref = make_ref()

    state = %{
      idle
      | task: %{ref: ref, pid: self()},
        view: %{idle.view | status: :running, kind: "factory_provision"}
    }

    message = "Factory provisioning verified; device reset."

    assert {:noreply, verified} =
             Workbench.Operations.handle_info({:factory_verified, self(), message}, state)

    assert verified.view.flash_verified
    assert verified.view.connection.status == :waiting
    assert verified.view.status == :running

    connection = %{status: :unavailable, message: "USB not ready; no retry"}

    for event <- [
          {ref, {:factory_complete, message, connection}},
          {ref, {:error, "private error"}},
          {:DOWN, ref, :process, self(), :killed}
        ] do
      assert {:noreply, done} = Workbench.Operations.handle_info(event, verified)
      assert done.task == nil
      assert done.view.status == :succeeded
      assert done.view.result == message
      assert done.view.connection.status == :unavailable
      refute done.view.connection.message =~ "private"
    end

    assert {:noreply, ^idle} =
             Workbench.Operations.handle_info({:factory_verified, self(), message}, idle)
  end

  test "successful factory reconnect exposes observed USB information separately from the flash result" do
    {:ok, idle} = Workbench.Operations.init(nil)
    ref = make_ref()

    state = %{
      idle
      | task: %{ref: ref},
        view: %{idle.view | status: :running, kind: "factory_provision"}
    }

    info = %{
      address: "198.18.234.2",
      interface: "enxusb",
      version: "new",
      target: "ec100",
      runtime: "Elixir 1.20 · OTP 29",
      read_at: "2026-10-22T12:00:00Z"
    }

    connection = %{status: :connected, device: info}

    assert {:noreply, done} =
             Workbench.Operations.handle_info(
               {ref, {:factory_complete, "Flash verified", connection}},
               state
             )

    assert done.view.status == :succeeded
    assert done.view.connection == connection
  end

  test "unknown workbench operations never start a worker" do
    {:ok, idle} = Workbench.Operations.init(nil)

    assert {:reply, {:error, _}, ^idle} =
             Workbench.Operations.handle_call(
               {:start, "publish", nil, nil},
               {self(), make_ref()},
               idle
             )
  end
end

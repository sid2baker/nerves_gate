defmodule Workbench.OperationsTest do
  use ExUnit.Case, async: false

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
          owner: Workbench.FactoryProvisioning,
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

    plan = %{
      owner: Workbench.FactoryProvisioning,
      dir: dir,
      public: %{kind: :factory, token: "token", backup: backup}
    }

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

  test "background reads cannot interrupt active work, stopping or a destructive review" do
    {:ok, idle} = Workbench.Operations.init(nil)

    for state <- [
          %{idle | task: %{ref: make_ref()}},
          %{idle | stopping: true},
          %{idle | review: %{public: %{token: "review"}}}
        ] do
      assert {:noreply, ^state} = Workbench.Operations.handle_cast(:read_discovered, state)
    end
  end

  test "information failures are recorded per device and never retried by another discovery notification" do
    {ref, running} = information_read_state()

    assert {:noreply, done} =
             Workbench.Operations.handle_info(
               {ref, {:error, "Verify the host key and authorize your key."}},
               running
             )

    assert done.view.status == :failed
    assert_receive {:"$gen_cast", :read_discovered}
    assert [device] = Workbench.LANDiscovery.snapshot().devices
    assert device.info_read.status == :failed
    assert device.info_read.message =~ "host key"
    refute Workbench.Devices.needs_info?(device)
    assert {:noreply, ^done} = Workbench.Operations.handle_cast(:read_discovered, done)
  end

  test "information worker exits leave a safe per-device failure and permit the next candidate" do
    {ref, running} = information_read_state()

    assert {:noreply, done} =
             Workbench.Operations.handle_info(
               {:DOWN, ref, :process, self(), {:unexpected, "secret"}},
               running
             )

    assert [device] = Workbench.LANDiscovery.snapshot().devices
    assert device.info_read.status == :failed
    refute device.info_read.message =~ "secret"
    assert done.task == nil
    assert_receive {:"$gen_cast", :read_discovered}
  end

  test "background information reads preserve the preceding operation result and recovery guidance" do
    for result <- [:ok, :error, :exit] do
      {ref, running} = information_read_state()

      previous = %{
        running.view
        | kind: "firmware_update",
          status: :failed,
          result: "Inspect the device before retrying",
          recovery: %{backup: "/backups/retained"}
      }

      running = Map.put(running, :background_previous_view, previous)

      event =
        if result == :exit,
          do: {:DOWN, ref, :process, self(), :killed},
          else: {ref, {result, "Information result"}}

      assert {:noreply, done} = Workbench.Operations.handle_info(event, running)
      assert done.view == previous
      assert done.task == nil
      refute Map.has_key?(done, :background_previous_view)
      assert [device] = Workbench.LANDiscovery.snapshot().devices
      assert device.info_read.status == if(result == :ok, do: :succeeded, else: :failed)
    end
  end

  # Stage host read-model state only. These tests start no worker or SSH connection.
  defp information_read_state do
    original = :sys.get_state(Workbench.LANDiscovery)
    on_exit(fn -> :sys.replace_state(Workbench.LANDiscovery, fn _ -> original end) end)
    address = "gateway.example.ts.net"
    {:ok, discovery} = Workbench.LANDiscovery.init(nil)
    {:reply, :ok, discovery} = Workbench.LANDiscovery.handle_call({:add, address}, nil, discovery)

    {:reply, :ok, discovery} =
      Workbench.LANDiscovery.handle_call({:read, address, :reading, nil}, nil, discovery)

    :sys.replace_state(Workbench.LANDiscovery, fn _ -> discovery end)
    {:ok, idle} = Workbench.Operations.init(nil)
    ref = make_ref()

    view =
      Map.merge(idle.view, %{
        kind: "device_info",
        status: :running,
        context: %{subject: address, device: nil}
      })

    {ref, %{idle | task: %{ref: ref}, view: view}}
  end

  test "physical readiness rows remain structured and failed checks never count as success" do
    {:ok, idle} = Workbench.Operations.init(nil)

    for status <- [:passed, :failed, :skipped] do
      ref = make_ref()
      rows = [%{id: "hardware_readiness", status: status, detail: "Observed readiness"}]
      result = %{profile: "backup", rows: rows}

      running = %{
        idle
        | task: %{ref: ref},
          view: %{idle.view | kind: "hardware_test", status: :running}
      }

      assert {:noreply, done} =
               Workbench.Operations.handle_info({ref, {:hardware_checks, result}}, running)

      assert done.view.checks == result
      assert done.view.status == if(status == :passed, do: :succeeded, else: :failed)
      assert done.view.result =~ "not changed or exercised"
    end
  end

  test "only a matching device's read-only assisted observation can be cooperatively cancelled" do
    {:ok, idle} = Workbench.Operations.init(nil)

    for kind <- ["hardware_failover", "reboot_verify", "firmware_update", "factory_provision"] do
      running = %{
        idle
        | task: %{pid: self(), ref: make_ref()},
          view:
            Map.merge(idle.view, %{
              kind: kind,
              status: :running,
              context: %{subject: "usb-device"}
            })
      }

      assert {:reply, {:error, _}, ^running} =
               Workbench.Operations.handle_call({:cancel_observation, "other"}, nil, running)

      if kind in ["hardware_failover", "reboot_verify"] do
        assert {:reply, :ok, pending} =
                 Workbench.Operations.handle_call(
                   {:cancel_observation, "usb-device"},
                   nil,
                   running
                 )

        assert pending.task == running.task
        assert pending.view.status == :running
        assert_receive :cancel_hardware_observation
      else
        assert {:reply, {:error, _}, ^running} =
                 Workbench.Operations.handle_call(
                   {:cancel_observation, "usb-device"},
                   nil,
                   running
                 )

        refute_receive :cancel_hardware_observation
      end
    end
  end

  test "reboot reviews cannot authorize firmware or factory writes and expire without device effects" do
    {:ok, idle} = Workbench.Operations.init(nil)

    plan = %{
      owner: Workbench.Hardware,
      public: %{kind: :reboot, token: "reboot", address: "usb-device"},
      expires: System.monotonic_time(:millisecond) + 60_000
    }

    state = %{
      idle
      | review: plan,
        view: %{idle.view | kind: "reboot_review", review: plan.public}
    }

    assert {:reply, {:error, _}, ^state} =
             Workbench.Operations.handle_call(
               {:confirm_firmware, "reboot", "usb-device"},
               nil,
               state
             )

    assert {:reply, {:error, _}, ^state} =
             Workbench.Operations.handle_call(
               {:confirm_factory, "reboot", "erase", "true"},
               nil,
               state
             )

    assert {:reply, {:error, _}, ^state} =
             Workbench.Operations.handle_call(
               {:confirm_reboot, "wrong", "usb-device"},
               nil,
               state
             )

    assert {:reply, {:error, _}, ^idle} =
             Workbench.Operations.handle_call(
               {:confirm_reboot, "reboot", "usb-device"},
               nil,
               idle
             )

    assert {:noreply, expired} =
             Workbench.Operations.handle_info({:expire_review, "reboot"}, state)

    assert expired.review == nil
    assert expired.view.result =~ "Reboot observation review expired"
  end

  test "diagnostics and assisted test results remain structured and honestly labelled" do
    {:ok, idle} = Workbench.Operations.init(nil)
    ref = make_ref()

    running = %{
      idle
      | task: %{ref: ref},
        view: %{idle.view | kind: "hardware_diagnostics", status: :running}
    }

    report = %{device: %{"target" => "ec100"}}

    assert {:noreply, done} =
             Workbench.Operations.handle_info({ref, {:diagnostics, report}}, running)

    assert done.view.diagnostic_report == report
    assert done.view.status == :succeeded
    running = %{running | view: %{idle.view | kind: "hardware_failover", status: :running}}

    result = %{
      profile: "assisted",
      rows: [%{id: "hardware_backup", status: :failed, detail: "Restore Ethernet"}]
    }

    assert {:noreply, done} =
             Workbench.Operations.handle_info({ref, {:hardware_checks, result}}, running)

    assert done.view.status == :failed
    assert done.view.result =~ "Restore all Ethernet cables"
    refute done.view.result =~ "not changed or exercised"
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

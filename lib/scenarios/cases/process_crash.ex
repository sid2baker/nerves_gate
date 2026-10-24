defmodule Scenarios.Cases.ProcessCrash do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.Recovery, as: Recovery
  alias Scenarios.Device, as: Device

  def spec,
    do: %{
      name: "local management recovers after isolated gateway process crashes (no tailnet)",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    {_private, line, fingerprint} = Device.ssh_key()
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.SSH, :add_key, [line])
    before = Recovery.baseline(vm)
    assert fingerprint in before.saved.ssh_keys

    # Negative control: a healthy page with an unchanged PID is not crash recovery.
    assert_raise ExUnit.AssertionError, ~r/Local recovery timed out/, fn ->
      Recovery.await_recovery(vm, before, NervesGate.ProjectionServer,
        timeout: 1_000,
        stability: 0
      )
    end

    # Negative control: healthy domain status cannot mask a stopped HTTP listener.
    # Explicitly restoring this listener validates the probe, not device recovery.
    listener = {NervesGateWeb.Endpoint, :http}

    assert :ok =
             Scenarios.Device.rpc(
               vm,
               Supervisor,
               :terminate_child,
               [NervesGateWeb.Endpoint, listener],
               5_000
             )

    try do
      assert_raise ExUnit.AssertionError, ~r/Local recovery timed out/, fn ->
        Recovery.await_recovery(vm, before, nil, timeout: 1_000, stability: 0)
      end

      assert :ok = Recovery.capture_failure(vm)
      refute Recovery.http_ready?(vm)
    after
      assert {:ok, _} =
               Scenarios.Device.rpc(
                 vm,
                 Supervisor,
                 :restart_child,
                 [NervesGateWeb.Endpoint, listener],
                 5_000
               )
    end

    Recovery.await_recovery(vm, before, nil, stability: 1_000)
    for target <- Recovery.targets(), do: Recovery.crash(vm, target)
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.SSH, :remove_key, [fingerprint])
  end
end

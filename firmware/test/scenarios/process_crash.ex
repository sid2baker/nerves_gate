defmodule NervesGate.Scenarios.ProcessCrash do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.{RecoveryChecks, ScenarioHelpers}
  alias NervesGate.TestQemu, as: Qemu

  def spec,
    do: %{name: "local management recovers after isolated gateway process crashes (no tailnet)"}

  def run(%{device: vm}) do
    {_private, line, fingerprint} = ScenarioHelpers.ssh_key()
    assert :ok = Qemu.call(vm, :ssh_add_key, [line])
    before = RecoveryChecks.baseline(vm)
    assert fingerprint in before.saved.ssh_keys

    # Negative control: a healthy page with an unchanged PID is not crash recovery.
    assert_raise ExUnit.AssertionError, ~r/Local recovery timed out/, fn ->
      RecoveryChecks.await_recovery(vm, before, NervesGate.ProjectionServer,
        timeout: 1_000,
        stability: 0
      )
    end

    # Negative control: healthy domain status cannot mask a stopped HTTP listener.
    # Explicitly restoring this listener validates the probe, not device recovery.
    listener = {NervesGateWeb.Endpoint, :http}

    assert :ok =
             :erpc.call(
               vm.node,
               Supervisor,
               :terminate_child,
               [NervesGateWeb.Endpoint, listener],
               5_000
             )

    try do
      assert_raise ExUnit.AssertionError, ~r/Local recovery timed out/, fn ->
        RecoveryChecks.await_recovery(vm, before, nil, timeout: 1_000, stability: 0)
      end

      assert :ok = RecoveryChecks.capture_failure(vm)
      refute RecoveryChecks.http_ready?(vm)
    after
      assert {:ok, _} =
               :erpc.call(
                 vm.node,
                 Supervisor,
                 :restart_child,
                 [NervesGateWeb.Endpoint, listener],
                 5_000
               )
    end

    RecoveryChecks.await_recovery(vm, before, nil, stability: 1_000)
    for target <- RecoveryChecks.targets(), do: RecoveryChecks.crash(vm, target)
    assert :ok = Qemu.call(vm, :ssh_remove_key, [fingerprint])
  end
end

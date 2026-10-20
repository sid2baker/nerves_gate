defmodule NervesGate.Scenarios.RestartIntensity do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.{RecoveryChecks, ScenarioHelpers}
  alias NervesGate.TestQemu, as: Qemu

  def spec,
    do: %{
      name:
        "four rapid gateway crashes exhaust supervision and the device reboots with saved settings"
    }

  def run(%{device: vm}) do
    {_private, line, fingerprint} = ScenarioHelpers.ssh_key()
    assert :ok = Qemu.call(vm, :ssh_add_key, [line])
    before = RecoveryChecks.baseline(vm)
    assert fingerprint in before.saved.ssh_keys
    assert RecoveryChecks.crash_loop(vm, NervesGate.ProjectionServer) == 4
    # No harness reset, resume or application restart can satisfy this assertion.
    RecoveryChecks.await_recovery(vm, before, :reboot, timeout: 180_000)
    assert :ok = Qemu.call(vm, :ssh_remove_key, [fingerprint])
  end
end

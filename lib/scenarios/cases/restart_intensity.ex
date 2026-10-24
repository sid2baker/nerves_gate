defmodule Scenarios.Cases.RestartIntensity do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.Recovery, as: Recovery
  alias Scenarios.Device, as: Device

  def spec,
    do: %{
      name:
        "four rapid gateway crashes exhaust supervision and the device reboots with saved settings",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    {_private, line, fingerprint} = Device.ssh_key()
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.SSH, :add_key, [line])
    before = Recovery.baseline(vm)
    assert fingerprint in before.saved.ssh_keys
    assert Recovery.crash_loop(vm, NervesGate.ProjectionServer) == 4
    # No harness reset, resume or application restart can satisfy this assertion.
    Recovery.await_recovery(vm, before, :reboot, timeout: 180_000)
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.SSH, :remove_key, [fingerprint])
  end
end

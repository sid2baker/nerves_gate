defmodule NervesGate.Scenarios.TailscaleLogin do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "real tailscaled obtains a private login link without enrolling a device"
  def boot_options, do: []

  def run(vm) do
    Qemu.check_firewall(vm)
    save(vm, settings("eth0"))
    Qemu.await(vm, "public Internet reachable", &internet?/1, 60_000)
    Qemu.await(vm, "Tailscale daemon ready", & &1.actions["remote.connect"].enabled)
    assert :ok = Qemu.call(vm, :remote_connect, ["nerves-gate-qemu"])

    status =
      Qemu.await(
        vm,
        "Tailscale control server returned a private login link",
        fn status ->
          status.remote_access.operation == nil && Qemu.login_ready?()
        end,
        45_000
      )

    assert status.remote_access.error == nil
    assert status.remote_access.auth_state != "authenticated"
    assert :ok = Qemu.call(vm, :remote_disconnect, [])
    Qemu.await(vm, "Tailscale disconnect completed", &is_nil(&1.remote_access.operation))
  end
end

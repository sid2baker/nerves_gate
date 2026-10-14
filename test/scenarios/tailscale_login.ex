defmodule NervesGate.Scenarios.TailscaleLogin do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.Remote.Policy
  alias NervesGate.TestQemu, as: Qemu

  @guest :"nerves_gate@192.168.77.2"

  def name, do: "Tailscale obtains a private login link and defers HTTPS until enrollment"
  def boot_options, do: []

  def run(vm) do
    assert_serve_policy()
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

    # Real unenrolled daemon: no listener is written before a usable identity.
    before = :erpc.call(@guest, Tailscale, :get_configuration, [], 5_000)
    assert before.serve == []

    assert {:error, :serve_not_ready} =
             :erpc.call(
               @guest,
               NervesGate.Remote.Tailscale,
               :execute,
               [:serve, %{dns_name: "not-enrolled.example.ts.net"}, nil],
               5_000
             )

    assert :erpc.call(@guest, Tailscale, :get_configuration, [], 5_000) == before
    assert :ok = Qemu.call(vm, :remote_disconnect, [])
    Qemu.await(vm, "Tailscale disconnect completed", &is_nil(&1.remote_access.operation))
  end

  @doc false
  def assert_serve_policy do
    ready = %{
      Policy.unavailable()
      | available: true,
        state: "online",
        auth_state: "authenticated",
        dns_name: "gateway.example.ts.net"
    }

    assert Policy.serve_dns_name(ready, nil) == ready.dns_name
    assert Policy.serve_dns_name(ready, ready.dns_name) == nil
    renamed = %{ready | dns_name: "renamed.example.ts.net"}
    assert Policy.serve_dns_name(renamed, ready.dns_name) == renamed.dns_name

    for pending <- [
          Policy.unavailable(),
          %{ready | available: false},
          %{ready | state: "offline"},
          %{ready | auth_state: "authenticating"},
          %{ready | auth_state: "needs_approval"},
          %{ready | auth_state: "stopped"},
          %{ready | dns_name: nil},
          %{ready | dns_name: ""},
          %{ready | error: %{code: "remote_failed", message: "Failed"}}
        ] do
      assert Policy.serve_dns_name(pending, nil) == nil
    end

    for operation <- ["connect", "configure", "disconnect", "sharing_enable", "serve"] do
      assert Policy.serve_dns_name(%{ready | operation: operation}, nil) == nil
    end
  end
end

defmodule NervesGate.Scenarios.TailscaleLogin do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.Remote.Policy
  alias NervesGate.TestQemu, as: Qemu

  @guest NervesGate.TestQemu.guest()

  def name, do: "Tailscale obtains a private login link and defers HTTPS until enrollment"
  def boot_options, do: []

  def run(vm) do
    assert_serve_policy()
    assert_auth_keys()
    Qemu.check_firewall(vm)
    save(vm, settings("eth0"))
    Qemu.await(vm, "public Internet reachable", &internet?/1, 60_000)
    Qemu.await(vm, "Tailscale daemon ready", & &1.actions["remote.connect"].enabled)
    # A deliberately invalid, non-secret key exercises the actual daemon path.
    key = "tskey-auth-qemu-invalid"
    assert :ok = Qemu.call(vm, :remote_connect, ["nerves-gate-qemu", [auth_key: key]])

    rejected =
      Qemu.await(
        vm,
        "invalid auth key rejected",
        fn status ->
          status.remote_access.operation == nil and status.remote_access.error != nil
        end,
        45_000
      )

    assert rejected.remote_access.auth_state == "error"
    assert rejected.remote_access.error.code == "remote_failed"
    refute Jason.encode!(rejected) =~ key
    refute inspect(:erpc.call(@guest, Tailscaled, :get_configuration, [], 5_000)) =~ key
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
    NervesGate.Scenarios.ProjectionStream.assert_remote_sign_in()

    # Real unenrolled daemon: no listener is written before a usable identity.
    before = :erpc.call(@guest, Tailscaled, :get_configuration, [], 5_000)
    assert before.serve == []
    assert :ok = :erpc.call(@guest, Tailscaled, :refresh_configuration, [], 5_000)
    assert :erpc.call(@guest, Tailscaled, :get_configuration, [], 5_000) == before

    assert {:error, :serve_not_ready} =
             :erpc.call(
               @guest,
               NervesGate.Remote.Tailscaled,
               :execute,
               [:serve, %{dns_name: "not-enrolled.example.ts.net"}, nil],
               5_000
             )

    assert :erpc.call(@guest, Tailscaled, :get_configuration, [], 5_000) == before
    assert :ok = Qemu.call(vm, :remote_disconnect, [])
    Qemu.await(vm, "Tailscale disconnect completed", &is_nil(&1.remote_access.operation))
  end

  @doc false
  def assert_auth_keys do
    assert {:ok, %{hostname: "gateway", auth_key: "test-key"}} =
             Policy.validate(:connect, %{"hostname" => "GATEWAY", "auth_key" => "test-key"})

    for key <- [nil, "", "   ", [], String.duplicate("x", 4097)] do
      assert {:error, %{code: "invalid_parameters"}} =
               Policy.validate(:connect, %{"hostname" => "gateway", "auth_key" => key})
    end

    assert {:error, _} =
             Policy.validate(:configure, %{"hostname" => "gateway", "auth_key" => "test-key"})

    assert {:error, _} =
             Policy.validate(:connect, %{
               "hostname" => "gateway",
               "auth_key" => "test-key",
               "extra" => true
             })

    assert %{health: ["Failed [private key]"]} =
             Policy.sanitize(%{health: ["Failed tskey-auth-test-key"]})

    refute Map.has_key?(Policy.sanitize(%{auth_key: "test-key"}), :auth_key)
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

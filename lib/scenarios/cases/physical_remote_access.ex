defmodule Scenarios.Cases.PhysicalRemoteAccess do
  @moduledoc "Read-only physical Tailscale and pinned SSH checks. Never changes keys or enrollment."
  import ExUnit.Assertions
  alias Scenarios.Device

  def spec do
    %{
      name:
        "Physical remote access: enrollment, pinned SSH and unauthorized-key rejection (read-only)",
      requires: %{device: [], fixture: [:physical]},
      opt_in: true
    }
  end

  def run(%{device: device}) do
    status = Device.rpc(device, NervesGate, :status)
    assert status.device.available, "Gateway status is unavailable"
    assert status.remote.available and status.remote.state == "online", "Tailscale is not online"
    assert status.remote.auth_state == "authenticated", "Tailscale is not enrolled"

    assert NervesGate.Remote.Policy.tag() in (status.remote.tags || []),
           "Required Tailscale tag is not granted"

    # Resolve through the verified directory; never accept a supplied SSH identity
    # or trust an unauthenticated address/host key from discovery.
    {:ok, gateway} = Workbench.Gateways.fetch(device.node)
    assert {:ok, fingerprints} = Device.rpc(device, NervesGate.SSH, :host_key_fingerprints)
    assert fingerprints != [], "No served SSH host keys were reported"

    case Workbench.SSH.connect(gateway.address, 22, Workbench.SSH.verified(fingerprints)) do
      {:ok, connection} -> :ssh.close(connection)
      {:error, _} -> flunk("Pinned SSH with the operator's existing key failed; no key was added")
    end

    # The ephemeral key never leaves memory, is never registered and sends no
    # password/PIN attempts. Require an authentication rejection, not any timeout.
    {key, _public, _fingerprint} = Device.ssh_key()

    options = [
      user: ~c"nerves_gate",
      auth_methods: ~c"publickey",
      key_cb: {Device, [key: key, fingerprints: fingerprints]},
      silently_accept_hosts: false
    ]

    case Workbench.SSH.connect(gateway.address, 22, options) do
      {:error, ~c"Unable to connect using the available authentication methods"} ->
        :ok

      {:ok, connection} ->
        :ssh.close(connection)
        flunk("An unregistered SSH key was accepted")

      {:error, _} ->
        flunk("SSH did not establish an authentication rejection; result is inconclusive")
    end
  end
end

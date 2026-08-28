defmodule NervesGate.SSH.ConfigurationTest do
  use ExUnit.Case, async: true

  test "NervesSSH has no automatic application child" do
    assert Supervisor.which_children(NervesSSH.Supervisor) == []
    assert Process.whereis(NervesSSH) == nil
    assert NervesGate.SSH.status().state == :disabled
  end

  test "nerves_pack cannot own SSH startup" do
    dependencies = Mix.Project.config()[:deps] |> Enum.map(&elem(&1, 0))

    assert :nerves_ssh in dependencies
    refute :nerves_pack in dependencies
  end

  test "target firmware has no developer keys or LAN SSH advertisements" do
    target_config = File.read!("config/target.exs")

    refute target_config =~ "id_rsa.pub"
    refute target_config =~ "id_ecdsa.pub"
    refute target_config =~ "id_ed25519.pub"
    refute target_config =~ "authorized_keys"
    refute target_config =~ ~s(protocol: "ssh")
    refute target_config =~ ~s(protocol: "sftp-ssh")
    refute target_config =~ ":nerves_pack"
  end

  test "Tailnet effects explicitly keep Tailscale SSH disabled" do
    enrollment = File.read!("lib/nerves_gate/tailnet/enrollment.ex")
    routes = File.read!("lib/nerves_gate/subnet_router.ex")
    sources = enrollment <> routes

    assert enrollment =~ "client.set(ssh: false)"
    assert routes =~ "Tailscale.set(ssh: false"
    refute sources =~ "ssh: true"
    refute sources =~ "--ssh"
    refute sources =~ "RunSSH"
  end
end

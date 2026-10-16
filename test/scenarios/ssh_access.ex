defmodule NervesGate.Scenarios.SshAccess do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def spec do
    %{
      name: "VintageNetDirect USB-only SSH; keys persist, revoke and fail closed on write errors",
      fresh_disk: true
    }
  end

  def run(%{device: vm}) do
    assert Qemu.status(vm).system.target == "x86_64"
    await_ssh(vm)
    {key, line, fingerprint} = ssh_key()

    assert {:error, _} = password(vm, vm.forwards.ssh, ~c"root", ~c"nerves_gate")
    assert {:error, _} = ssh_public_key(vm, key)
    reject_invalid(vm, line)
    assert :ok = Qemu.call(vm, :ssh_add_key, [line])
    assert :ok = Qemu.call(vm, :ssh_add_key, [String.trim(line) <> " another comment"])
    assert Enum.count(Qemu.status(vm).ssh.keys, &(&1.fingerprint == fingerprint)) == 1
    assert_key_works(vm, key)

    Qemu.reboot(vm)
    await_ssh(vm)
    assert_key_works(vm, key)
    assert :ok = Qemu.call(vm, :ssh_remove_key, [fingerprint])
    assert {:error, _} = ssh_public_key(vm, key)
    path = :erpc.call(vm.node, NervesGate.SSH.Keys, :path, [])
    assert {:ok, %{size: 0}} = :erpc.call(vm.node, File, :stat, [path])
    Qemu.reboot(vm)
    await_ssh(vm)
    refute Enum.any?(Qemu.status(vm).ssh.keys, &(&1.fingerprint == fingerprint))
    assert {:error, _} = ssh_public_key(vm, key)
    reject_failed_save(vm, line, key)

    Qemu.connect_usb(vm)

    assert %{type: VintageNetDirect} =
             :erpc.call(vm.node, VintageNet, :get_configuration, ["usb0"])

    assert {:ok, connection} = password(vm, vm.forwards.usb, ~c"root", ~c"nerves_gate")
    :ok = :ssh.close(connection)
    assert {:error, _} = password(vm, vm.forwards.usb, ~c"root", ~c"wrong")
    assert {:error, _} = password(vm, vm.forwards.usb, ~c"other", ~c"nerves_gate")
    assert {:error, _} = password(vm, vm.forwards.ssh, ~c"root", ~c"nerves_gate")
    assert {:error, _} = password(vm, vm.forwards.usb, ~c"root", ~c"")
    reject_conflicting_paths(vm)

    # Removing the actual kernel path immediately revokes password eligibility.
    {_, 0} = :erpc.call(vm.node, System, :cmd, ["ip", ~w"link set usb0 down"])
    refute_password(vm)
  end

  defp reject_conflicting_paths(vm) do
    {:ok, {a, b, c, d}} = :inet.parse_address(String.to_charlist(vm.usb.peer))
    overlap = "#{a}.#{b}.#{c}.#{Bitwise.bxor(d, 4)}/29"

    for {add, remove} <- [
          {["addr", "add", overlap, "dev", "eth1"], ["addr", "del", overlap, "dev", "eth1"]},
          {["route", "add", "#{vm.usb.peer}/32", "via", "192.168.77.1", "dev", "eth2"],
           ["route", "del", "#{vm.usb.peer}/32", "via", "192.168.77.1", "dev", "eth2"]}
        ] do
      {_, 0} = :erpc.call(vm.node, System, :cmd, ["ip", add])

      try do
        refute_password(vm)
      after
        {_, 0} = :erpc.call(vm.node, System, :cmd, ["ip", remove])
      end
    end

    assert {:ok, connection} = password(vm, vm.forwards.usb, ~c"root", ~c"nerves_gate")
    :ok = :ssh.close(connection)
  end

  defp refute_password(vm) do
    {:ok, peer} = :inet.parse_address(String.to_charlist(vm.usb.peer))

    assert {false, 1} =
             :erpc.call(vm.node, NervesGate.SSH.USBPassword, :check, [
               ~c"root",
               ~c"nerves_gate",
               {peer, 12_345},
               0
             ])
  end

  defp reject_invalid(vm, line) do
    before = Qemu.status(vm).ssh.keys

    for invalid <- [
          nil,
          %{},
          "",
          "not a key",
          "ssh-ed25519 !!!",
          line <> line,
          "from=\"*\" " <> line,
          "-----BEGIN OPENSSH PRIVATE KEY-----",
          String.duplicate("x", 8193)
        ] do
      assert {:error, %{code: "invalid_ssh_key"}} = Qemu.call(vm, :ssh_add_key, [invalid])
    end

    assert Qemu.status(vm).ssh.keys == before
  end

  defp reject_failed_save(vm, line, key) do
    path = :erpc.call(vm.node, NervesGate.SSH.Keys, :path, []) <> ".new"
    :ok = :erpc.call(vm.node, File, :mkdir, [path])
    before = Qemu.status(vm).ssh.keys

    try do
      assert {:error, %{code: "ssh_keys_unavailable"}} = Qemu.call(vm, :ssh_add_key, [line])
      assert Qemu.status(vm).ssh.keys == before
      assert {:error, _} = ssh_public_key(vm, key)
    after
      :ok = :erpc.call(vm.node, File, :rmdir, [path])
    end
  end

  defp assert_key_works(vm, key) do
    assert {:ok, connection} = ssh_public_key(vm, key)
    :ok = :ssh.close(connection)
  end

  defp password(vm, port, user, password),
    do: ssh_connect(vm, port, user: user, password: password, auth_methods: ~c"password")
end

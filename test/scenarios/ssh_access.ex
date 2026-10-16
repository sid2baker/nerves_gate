defmodule NervesGate.Scenarios.SshAccess do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  @guest NervesGate.TestQemu.guest()

  def name,
    do: "USB-only SSH password; validated keys persist, revoke and fail closed on write errors"

  def boot_options, do: [usb: true]

  def run(vm) do
    assert Qemu.status(vm).system.target == "x86_64"
    await_ssh()
    {key, line, fingerprint} = ssh_key()

    assert {:error, _} = password(Qemu.current().forwards.ssh, ~c"root", ~c"nerves_gate")
    assert {:error, _} = public_key(key)
    reject_invalid(vm, line)
    assert :ok = Qemu.call(vm, :ssh_add_key, [line])
    assert :ok = Qemu.call(vm, :ssh_add_key, [String.trim(line) <> " another comment"])
    assert Enum.count(Qemu.status(vm).ssh.keys, &(&1.fingerprint == fingerprint)) == 1
    assert_key_works(key)

    Qemu.reboot(vm)
    await_ssh()
    assert_key_works(key)
    assert :ok = Qemu.call(vm, :ssh_remove_key, [fingerprint])
    assert {:error, _} = public_key(key)
    path = :erpc.call(@guest, NervesGate.SSH.Keys, :path, [])
    assert {:ok, %{size: 0}} = :erpc.call(@guest, File, :stat, [path])
    Qemu.reboot(vm)
    await_ssh()
    refute Enum.any?(Qemu.status(vm).ssh.keys, &(&1.fingerprint == fingerprint))
    assert {:error, _} = public_key(key)
    reject_failed_save(vm, line, key)

    Qemu.connect_usb(vm)
    assert {:ok, connection} = password(vm.forwards.usb, ~c"root", ~c"nerves_gate")
    :ok = :ssh.close(connection)
    assert {:error, _} = password(vm.forwards.usb, ~c"root", ~c"wrong")
    assert {:error, _} = password(vm.forwards.usb, ~c"other", ~c"nerves_gate")
    assert {:error, _} = password(vm.forwards.ssh, ~c"root", ~c"nerves_gate")
    assert {:error, _} = password(vm.forwards.usb, ~c"root", ~c"")
    reject_conflicting_paths()

    # Removing the actual kernel path immediately revokes password eligibility.
    {_, 0} = :erpc.call(@guest, System, :cmd, ["ip", ~w"link set usb0 down"])

    assert {false, 1} =
             :erpc.call(@guest, NervesGate.SSH.USBPassword, :check, [
               ~c"root",
               ~c"nerves_gate",
               {{172, 31, 255, 2}, 12_345},
               0
             ])
  end

  defp reject_conflicting_paths do
    for {add, remove} <- [
          {~w"addr add 172.31.255.5/29 dev eth1", ~w"addr del 172.31.255.5/29 dev eth1"},
          {~w"route add 172.31.255.2/32 via 192.168.77.1 dev eth2",
           ~w"route del 172.31.255.2/32 via 192.168.77.1 dev eth2"}
        ] do
      {_, 0} = :erpc.call(@guest, System, :cmd, ["ip", add])

      try do
        assert {false, 1} =
                 :erpc.call(@guest, NervesGate.SSH.USBPassword, :check, [
                   ~c"root",
                   ~c"nerves_gate",
                   {{172, 31, 255, 2}, 12_345},
                   0
                 ])
      after
        {_, 0} = :erpc.call(@guest, System, :cmd, ["ip", remove])
      end
    end

    assert {:ok, connection} = password(Qemu.current().forwards.usb, ~c"root", ~c"nerves_gate")
    :ok = :ssh.close(connection)
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
    path = :erpc.call(@guest, NervesGate.SSH.Keys, :path, []) <> ".new"
    :ok = :erpc.call(@guest, File, :mkdir, [path])
    before = Qemu.status(vm).ssh.keys

    try do
      assert {:error, %{code: "ssh_keys_unavailable"}} = Qemu.call(vm, :ssh_add_key, [line])
      assert Qemu.status(vm).ssh.keys == before
      assert {:error, _} = public_key(key)
    after
      :ok = :erpc.call(@guest, File, :rmdir, [path])
    end
  end

  defp assert_key_works(key) do
    assert {:ok, connection} = public_key(key)
    :ok = :ssh.close(connection)
  end

  defp password(port, user, password),
    do: ssh_connect(port, user: user, password: password, auth_methods: ~c"password")

  defp public_key(key), do: ssh_public_key(Qemu.current(), key)
end

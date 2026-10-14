defmodule NervesGate.Scenarios.SshAccess do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.TestQemu, as: Qemu

  @behaviour :ssh_client_key_api
  @guest :"nerves_gate@192.168.77.2"
  @management {192, 168, 77, 2}
  @usb {172, 31, 255, 1}

  def name,
    do: "USB-only SSH password; validated keys persist, revoke and fail closed on write errors"

  def boot_options, do: [usb: true]

  def run(vm) do
    assert Qemu.status(vm).system.target == "x86_64"
    key = :public_key.generate_key({:namedCurve, :ed25519})
    decoded = :ssh_file.extract_public_key(key)
    line = :ssh_file.encode([{decoded, [comment: ~c"QEMU SSH scenario"]}], :auth_keys)
    fingerprint = to_string(:ssh.hostkey_fingerprint(:sha256, decoded))

    assert {:error, _} = password(@management, ~c"root", ~c"nerves_gate")
    assert {:error, _} = public_key(key)
    reject_invalid(vm, line)
    assert :ok = Qemu.call(vm, :ssh_add_key, [line])
    assert :ok = Qemu.call(vm, :ssh_add_key, [String.trim(line) <> " another comment"])
    assert Enum.count(Qemu.status(vm).ssh.keys, &(&1.fingerprint == fingerprint)) == 1
    assert_key_works(key)

    Qemu.reboot(vm)
    assert_key_works(key)
    assert :ok = Qemu.call(vm, :ssh_remove_key, [fingerprint])
    assert {:error, _} = public_key(key)
    Qemu.reboot(vm)
    refute Enum.any?(Qemu.status(vm).ssh.keys, &(&1.fingerprint == fingerprint))
    assert {:error, _} = public_key(key)
    reject_failed_save(vm, line, key)

    Qemu.connect_usb(vm)
    assert {:ok, connection} = password(@usb, ~c"root", ~c"nerves_gate")
    :ok = :ssh.close(connection)
    assert {:error, _} = password(@usb, ~c"root", ~c"wrong")
    assert {:error, _} = password(@usb, ~c"other", ~c"nerves_gate")
    assert {:error, _} = password(@management, ~c"root", ~c"nerves_gate")
    assert {:error, _} = password(@usb, ~c"root", ~c"")
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

    assert {:ok, connection} = password(@usb, ~c"root", ~c"nerves_gate")
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

  defp password(ip, user, password),
    do: connect(ip, user: user, password: password, auth_methods: ~c"password")

  defp public_key(key),
    do:
      connect(@management,
        user: ~c"root",
        key_cb: {__MODULE__, key: key},
        auth_methods: ~c"publickey",
        preferred_algorithms: [public_key: [:"ssh-ed25519"]]
      )

  defp connect(ip, options) do
    :ssh.connect(
      ip,
      22,
      options ++
        [
          silently_accept_hosts: true,
          save_accepted_host: false,
          user_interaction: false,
          connect_timeout: 3000
        ],
      5000
    )
  end

  # Ephemeral generated credentials for this owned guest only. No workstation keys.
  @impl true
  def user_key(:"ssh-ed25519", options), do: {:ok, options[:key_cb_private][:key]}
  def user_key(_, _), do: {:error, :not_found}
  @impl true
  def is_host_key(_, _, _, _, _), do: true
  @impl true
  def add_host_key(_, _, _, _), do: :ok
end

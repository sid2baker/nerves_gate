defmodule NervesGate.Scenarios.FirmwareUpgrade do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  @guest NervesGate.TestQemu.guest()
  @firmware "_build/x86_64_dev/nerves/images/nerves_gate.fw"

  def name, do: "real SSH/fwup upgrades A → B → A preserve SSH access and saved settings"
  def boot_options, do: []

  def run(vm) do
    assert Qemu.status(vm).system.target == "x86_64"
    assert slot?("a")
    {key, line, fingerprint} = ssh_key()
    assert :ok = Qemu.call(vm, :ssh_add_key, [line])
    saved = save(vm, settings("eth0"))

    # Use the same firmware, disk and VM: only fwup selects the next boot slot.
    # Its normal success callback reboots the guest; the bench does not reset it.
    for slot <- ["b", "a"] do
      await_ssh()
      assert {:ok, connection} = ssh_public_key(vm, key)

      try do
        upload(connection)
      after
        :ssh.close(connection)
      end

      restored =
        Qemu.await(
          vm,
          "firmware booted from slot #{slot}",
          fn status ->
            slot?(slot) && status.network.setup_completed && not status.network.recovering
          end,
          100_000
        )

      assert restored.network.desired == saved
      assert restored.network.pending == nil
      assert Enum.any?(restored.ssh.keys, &(&1.fingerprint == fingerprint))
    end

    await_ssh()
    assert {:ok, connection} = ssh_public_key(vm, key)
    :ok = :ssh.close(connection)
  end

  defp slot?(slot) do
    # ops.fw checks the mounted root partition as well as the next-boot metadata.
    # During reboot, an RPC error is simply not ready yet.
    match?(
      {:ok, %{active: ^slot, next: ^slot}},
      :rpc.call(@guest, Nerves.Runtime.FwupOps, :status, [], 2000)
    )
  end

  defp upload(connection) do
    assert {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    assert :success = :ssh_connection.subsystem(connection, channel, ~c"fwup", 5000)

    for chunk <- File.stream!(@firmware, 64 * 1024) do
      assert :ok = :ssh_connection.send(connection, channel, chunk, 30_000)
    end

    :ssh_connection.send_eof(connection, channel)
    await_upload(connection, channel, System.monotonic_time(:millisecond) + 60_000)
  end

  defp await_upload(connection, channel, deadline) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, _type, data}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(data))
        await_upload(connection, channel, deadline)

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        await_upload(connection, channel, deadline)

      {:ssh_cm, ^connection, {:exit_status, ^channel, status}} ->
        assert status == 0, "Guest fwup failed with exit status #{status}"

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        flunk("Firmware upload closed without a successful fwup exit status")
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        flunk("Timed out waiting for guest fwup")
    end
  end
end

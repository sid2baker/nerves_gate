defmodule Scenarios.Cases.SshAccess do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec do
    %{
      name: "VintageNetDirect USB-only SSH; keys persist, revoke and fail closed on write errors",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }
  end

  def run(%{device: vm}) do
    assert Scenarios.Device.status(vm).system.target == "x86_64"
    await_ssh(vm)
    assert_settings_events(vm)
    {key, line, fingerprint} = ssh_key()

    assert {:error, _} = password(vm, 22, ~c"root", ~c"nerves_gate")
    assert {:error, _} = ssh_public_key(vm, key)
    reject_invalid(vm, line)
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.SSH, :add_key, [line])

    assert :ok =
             Scenarios.Device.rpc(vm, NervesGate.SSH, :add_key, [
               String.trim(line) <> " another comment"
             ])

    assert Enum.count(Scenarios.Device.status(vm).ssh.keys, &(&1.fingerprint == fingerprint)) == 1
    assert_key_works(vm, key)

    Qemu.reboot(vm)
    await_ssh(vm)
    assert_key_works(vm, key)
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.SSH, :remove_key, [fingerprint])
    assert {:error, _} = ssh_public_key(vm, key)
    path = Scenarios.Device.rpc(vm, NervesGate.SSH.Keys, :path, [])
    assert {:ok, %{size: 0}} = Scenarios.Device.rpc(vm, File, :stat, [path])
    Qemu.reboot(vm)
    await_ssh(vm)
    refute Enum.any?(Scenarios.Device.status(vm).ssh.keys, &(&1.fingerprint == fingerprint))
    assert {:error, _} = ssh_public_key(vm, key)
    reject_failed_save(vm, line, key)

    Qemu.connect_usb(vm)

    assert %{type: VintageNetDirect} =
             Scenarios.Device.rpc(vm, VintageNet, :get_configuration, ["usb0"])

    assert {:ok, connection} = password(vm, vm.usb.port, ~c"root", ~c"nerves_gate")
    :ok = :ssh.close(connection)
    assert {:error, _} = password(vm, vm.usb.port, ~c"root", ~c"wrong")
    assert {:error, _} = password(vm, vm.usb.port, ~c"other", ~c"nerves_gate")
    assert {:error, _} = password(vm, 22, ~c"root", ~c"nerves_gate")
    assert {:error, _} = password(vm, vm.usb.port, ~c"root", ~c"")
    reject_conflicting_paths(vm)

    # Removing the actual kernel path immediately revokes password eligibility.
    {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, ["ip", ~w"link set usb0 down"])
    refute_password(vm)
  end

  defp assert_settings_events(vm) do
    view = NervesGateWeb.SettingsLive

    {:ok, server, projection} =
      NervesGate.ProjectionServer.subscribe({NervesGate.ProjectionServer, vm.node})

    raw =
      %Phoenix.LiveView.Socket{
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}, live_temp: %{}}
      }
      |> Phoenix.Component.assign(:projection, projection.status)
      |> Phoenix.LiveView.clear_flash()

    {:ok, socket} = rpc(vm, view, :mount, [%{}, %{}, raw])

    {:noreply, socket} =
      rpc(vm, view, :handle_event, ["key-draft", %{"ssh" => %{"public_key" => "invalid"}}, socket])

    {:noreply, socket} =
      rpc(vm, view, :handle_event, ["add-key", %{"ssh" => %{"public_key" => "invalid"}}, socket])

    assert socket.assigns.key_form[:public_key].value == "invalid"
    assert socket.assigns.flash["error"] =~ "public key"

    {_private, line, fingerprint} = ssh_key()

    {:noreply, socket} =
      rpc(vm, view, :handle_event, ["add-key", %{"ssh" => %{"public_key" => line}}, socket])

    assert socket.assigns.key_form[:public_key].value == ""

    Qemu.on_exit({:settings_key, fingerprint}, fn ->
      if Enum.any?(status(vm).ssh.keys, &(&1.fingerprint == fingerprint)),
        do: rpc(vm, NervesGate.SSH, :remove_key, [fingerprint])
    end)

    assert_receive {:projection, ^server, {:replace, :ssh, ssh}}, 2_000
    updated = NervesGate.Projection.apply(projection, {:replace, :ssh, ssh})
    assert Enum.any?(updated.status.ssh.keys, &(&1.fingerprint == fingerprint))

    {:noreply, _socket} =
      rpc(vm, view, :handle_event, ["remove-key", %{"fingerprint" => fingerprint}, socket])

    assert_receive {:projection, ^server, {:replace, :ssh, ssh}}, 2_000
    updated = NervesGate.Projection.apply(updated, {:replace, :ssh, ssh})
    refute Enum.any?(updated.status.ssh.keys, &(&1.fingerprint == fingerprint))
    Qemu.on_exit({:settings_key, fingerprint}, fn -> :ok end)
  end

  defp reject_conflicting_paths(vm) do
    {:ok, {a, b, c, d}} = :inet.parse_address(String.to_charlist(vm.usb.peer))
    overlap = "#{a}.#{b}.#{c}.#{Bitwise.bxor(d, 4)}/29"

    for {add, remove} <- [
          {["addr", "add", overlap, "dev", "eth1"], ["addr", "del", overlap, "dev", "eth1"]},
          {["route", "add", "#{vm.usb.peer}/32", "via", vm.management_host, "dev", "eth2"],
           ["route", "del", "#{vm.usb.peer}/32", "via", vm.management_host, "dev", "eth2"]}
        ] do
      {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, ["ip", add])

      try do
        refute_password(vm)
      after
        {_, 0} = Scenarios.Device.rpc(vm, System, :cmd, ["ip", remove])
      end
    end

    assert {:ok, connection} = password(vm, vm.usb.port, ~c"root", ~c"nerves_gate")
    :ok = :ssh.close(connection)
  end

  defp refute_password(vm) do
    {:ok, peer} = :inet.parse_address(String.to_charlist(vm.usb.peer))

    assert {false, 1} =
             Scenarios.Device.rpc(vm, NervesGate.SSH.USBPassword, :check, [
               ~c"root",
               ~c"nerves_gate",
               {peer, 12_345},
               0
             ])
  end

  defp reject_invalid(vm, line) do
    before = Scenarios.Device.status(vm).ssh.keys

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
      assert {:error, %{code: "invalid_ssh_key"}} =
               Scenarios.Device.rpc(vm, NervesGate.SSH, :add_key, [invalid])
    end

    assert Scenarios.Device.status(vm).ssh.keys == before
  end

  defp reject_failed_save(vm, line, key) do
    path = Scenarios.Device.rpc(vm, NervesGate.SSH.Keys, :path, []) <> ".new"
    :ok = Scenarios.Device.rpc(vm, File, :mkdir, [path])
    before = Scenarios.Device.status(vm).ssh.keys

    try do
      assert {:error, %{code: "ssh_keys_unavailable"}} =
               Scenarios.Device.rpc(vm, NervesGate.SSH, :add_key, [line])

      assert Scenarios.Device.status(vm).ssh.keys == before
      assert {:error, _} = ssh_public_key(vm, key)
    after
      :ok = Scenarios.Device.rpc(vm, File, :rmdir, [path])
    end
  end

  defp assert_key_works(vm, key) do
    assert {:ok, connection} = ssh_public_key(vm, key)
    :ok = :ssh.close(connection)
  end

  defp password(vm, port, user, password) do
    options = [user: user, password: password, auth_methods: ~c"password"]

    if port == vm.usb.port,
      do: Scenarios.Device.ssh(vm, :usb, options),
      else: Scenarios.Device.ssh(vm, port, options)
  end
end

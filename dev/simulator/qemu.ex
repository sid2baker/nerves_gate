defmodule NervesGate.Simulator.Qemu do
  @moduledoc false
  alias NervesGate.Simulator.Network

  def image(vm) do
    {_, 0} =
      MuonTrap.cmd(
        "fwup",
        ["-q", "-a", "-i", vm.factory_firmware, "-d", image_path(vm), "-t", "complete"],
        env: [{"NERVES_SERIAL_NUMBER", vm.serial}],
        stderr_to_stdout: true
      )

    vm
  end

  def boot(vm) do
    for socket <- Path.wildcard(Path.join(vm.dir, "*.sock")), do: File.rm!(socket)
    boot = System.unique_integer([:positive])
    # AF_UNIX limits the supplied path, not the resolved filesystem path.
    # Keep sockets relative to the shared project cwd, including in deep checkouts.
    socket_path = vm.dir |> Path.join("qmp.sock") |> Path.relative_to_cwd()
    stall = if vm.options[:receive_stall], do: "on", else: "off"

    args =
      [
        "-S",
        "-m",
        "1024",
        "-display",
        "none",
        "-monitor",
        "none",
        "-serial",
        "file:#{vm.dir}/console-#{boot}.log",
        "-pidfile",
        "#{vm.dir}/qemu.pid",
        "-qmp",
        "unix:#{socket_path},server=on,wait=off",
        "-blockdev",
        "driver=file,node-name=storage,filename=#{image_path(vm)}",
        "-blockdev",
        "driver=raw,node-name=disk,file=storage",
        "-device",
        "virtio-blk-pci,drive=disk,werror=report,rerror=report"
      ] ++
        Network.arguments(vm.dir, vm.address, vm.forwards, vm.usb) ++
        [
          "-object",
          "filter-buffer,id=lan1-stall,netdev=lan1,queue=tx,interval=3600000000,status=#{stall}"
        ]

    spec =
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           "qemu-system-x86_64",
           args,
           [
             stderr_to_stdout: true,
             logger_fun: fn line ->
               File.write!(Path.join(vm.dir, "qemu.log"), line <> "\n", [:append])
             end
           ]
         ]},
        id: :qemu,
        restart: :temporary
      )

    {:ok, daemon} = Supervisor.start_child(vm.supervisor, spec)

    poll(vm, "QMP socket", 10_000, fn ->
      unless Process.alive?(daemon), do: raise("QEMU exited; inspect #{vm.dir}/qemu.log")
      File.exists?(socket_path)
    end)

    {:ok, socket} =
      :gen_tcp.connect({:local, socket_path}, 0, [:binary, packet: :line, active: false], 2000)

    {:ok, greeting} = :gen_tcp.recv(socket, 0, 2000)
    true = Map.has_key?(Jason.decode!(greeting), "QMP")
    pid = vm.dir |> Path.join("qemu.pid") |> File.read!() |> String.trim() |> String.to_integer()
    vm = Map.merge(vm, %{socket: socket, daemon: daemon, pid: pid})
    qmp(vm, "qmp_capabilities", %{})
    :ok = Network.attach(vm.network)
    apply_cables(vm, Network.snapshot(vm.network).config.cables)
    :ok = Network.release(vm.network)
    qmp(vm, "cont", %{})
    await_boot(vm)
    vm
  end

  def await_boot(vm) do
    poll(vm, "device boot", 180_000, fn ->
      case status(vm) do
        %{system: %{target: "x86_64", node: name}} when name == vm.node -> true
        _ -> false
      end
    end)
  end

  def status(vm) do
    :erpc.call(vm.node, NervesGate, :status, [], 2000)
  catch
    :error, {:erpc, _} -> nil
  end

  def network(vm, patch) do
    case Network.configure(vm.network, patch) do
      {:error, reason} ->
        {:error, reason}

      {:ok, previous, config} ->
        if previous.internet != config.internet, do: unplug(vm)

        if previous.cables != config.cables or not Network.snapshot(vm.network).ready,
          do: apply_cables(vm, config.cables)

        :ok = Network.release(vm.network)
        log(vm, "faults.log", {:network, config})
        :ok
    end
  end

  defp unplug(vm) do
    apply_cables(vm, %{lan1: false, lan2: false})

    if qmp(vm, "query-status", %{})["running"] do
      poll(vm, "cables unplugged", 5000, fn ->
        observed = status(vm)
        observed && Enum.all?(observed.connections.ports, &(!&1.link))
      end)
    end
  end

  def release_lan1_receive(vm) do
    "tx" = qmp(vm, "qom-get", %{path: "/objects/lan1-stall", property: "queue"})
    "on" = qmp(vm, "qom-get", %{path: "/objects/lan1-stall", property: "status"})
    qmp(vm, "qom-set", %{path: "/objects/lan1-stall", property: "status", value: "off"})
    :ok
  end

  def remove_lan1(vm) do
    qmp(vm, "device_del", %{id: "lan1-nic"})
    :ok
  end

  def insert_lan1(vm) do
    devices = qmp(vm, "qom-list", %{path: "/machine/peripheral"})

    unless Enum.any?(devices, &(&1["name"] == "lan1-nic")) do
      qmp(vm, "device_add", %{
        driver: "virtio-net-pci",
        netdev: "lan1",
        id: "lan1-nic",
        mac: "52:54:00:12:34:56"
      })
    end

    link(vm, :lan1, Network.snapshot(vm.network).config.cables.lan1)
    :ok
  end

  def fail_disk_writes(vm) do
    qmp(vm, "blockdev-add", %{
      driver: "blkdebug",
      "node-name": "write-fault",
      image: "storage",
      "inject-error": [
        %{event: "write_aio", iotype: "write", errno: 5, immediately: true, once: false}
      ]
    })

    qmp(vm, "blockdev-reopen", %{
      options: [%{"node-name": "disk", driver: "raw", file: "write-fault"}]
    })

    :ok
  end

  def restore_disk_writes(vm) do
    qmp(vm, "blockdev-reopen", %{
      options: [%{"node-name": "disk", driver: "raw", file: "storage"}]
    })

    qmp(vm, "blockdev-del", %{"node-name": "write-fault"})
    :ok
  end

  def failed_disk_writes(vm) do
    vm
    |> qmp("query-blockstats", %{})
    |> Enum.map(&get_in(&1, ["stats", "failed_wr_operations"]))
    |> Enum.reject(&is_nil/1)
    |> Enum.sum()
  end

  def pause(vm), do: qmp(vm, "stop", %{})
  def resume(vm), do: qmp(vm, "cont", %{})

  def reboot(vm) do
    qmp(vm, "system_reset", %{})
    Node.disconnect(vm.node)
    await_boot(vm)
    :ok
  end

  def power_cycle(vm) do
    owned!(vm)
    :ok = Network.detach(vm.network)
    log(vm, "faults.log", :intentional_power_cut)
    :ok = :sys.suspend(vm.daemon)

    try do
      {_, 0} = System.cmd("kill", ["-KILL", to_string(vm.pid)])
      poll(vm, "power cut", 5000, fn -> not File.exists?("/proc/#{vm.pid}") end)
      :ok = Supervisor.terminate_child(vm.supervisor, :qemu)
    after
      if Process.alive?(vm.daemon), do: :sys.resume(vm.daemon)
    end

    :gen_tcp.close(vm.socket)
    Node.disconnect(vm.node)
    boot(vm)
  end

  def fresh(vm, options) do
    stop(vm)
    File.rm!(image_path(vm))
    {:ok, _, _} = Network.configure(vm.network, vm.initial_network)
    vm |> Map.put(:options, options) |> image() |> boot()
  end

  def stop(vm) do
    owned!(vm)
    :ok = Network.detach(vm.network)
    :ok = Supervisor.terminate_child(vm.supervisor, :qemu)
    poll(vm, "QEMU stopped", 5000, fn -> not File.exists?("/proc/#{vm.pid}") end)
    :gen_tcp.close(vm.socket)
    Node.disconnect(vm.node)
    :ok
  end

  def image_path(vm), do: Path.join(vm.dir, "gateway.img")

  def poll(vm, phase, timeout, check), do: poll_until(vm, phase, deadline(timeout), check)

  defp poll_until(vm, phase, deadline, check) do
    value = check.()

    cond do
      value ->
        value

      System.monotonic_time(:millisecond) >= deadline ->
        raise("Timed out: #{phase}; diagnostics: #{vm.dir}")

      true ->
        Process.sleep(500)
        poll_until(vm, phase, deadline, check)
    end
  end

  defp owned!(vm) do
    true =
      Enum.any?(Supervisor.which_children(vm.supervisor), fn {id, pid, _, _} ->
        id == :qemu and pid == vm.daemon
      end)

    wrapper = MuonTrap.Daemon.os_pid(vm.daemon)
    status = File.read!("/proc/#{vm.pid}/status")
    unless Regex.match?(~r/^PPid:\s+#{wrapper}$/m, status), do: raise("QEMU ownership changed")
  end

  defp apply_cables(vm, cables), do: Enum.each(cables, fn {port, up} -> link(vm, port, up) end)
  defp link(vm, port, up), do: qmp(vm, "set_link", %{name: "#{port}-nic", up: up})

  defp qmp(vm, command, arguments) do
    owned!(vm)
    id = System.unique_integer([:positive])
    request = Jason.encode!(%{execute: command, arguments: arguments, id: id})
    log(vm, "qmp.log", {:send, request})
    :ok = :gen_tcp.send(vm.socket, request <> "\r\n")
    reply(vm, id, deadline(3000))
  end

  defp reply(vm, id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    {:ok, line} = :gen_tcp.recv(vm.socket, 0, remaining)
    log(vm, "qmp.log", {:recv, line})

    case Jason.decode!(line) do
      %{"id" => ^id, "return" => value} -> value
      %{"id" => ^id, "error" => error} -> raise("QMP failed: #{inspect(error)}")
      _ -> reply(vm, id, deadline)
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp log(vm, file, value) do
    File.write!(
      Path.join(vm.dir, file),
      "#{System.system_time(:millisecond)} #{inspect(value)}\n",
      [:append]
    )
  end
end

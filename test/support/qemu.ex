defmodule NervesGate.TestQemu do
  @moduledoc "Test-only controls for an owned QEMU, never a physical device."
  import ExUnit.Assertions
  import ExUnit.Callbacks

  @guest :"nerves_gate@192.168.77.2"

  def start do
    if File.read_link!("/proc/self/ns/net") == System.fetch_env!("NERVES_GATE_HOST_NETNS"),
      do: raise("Refusing to fault networking in the workstation namespace")

    dir = Path.join("_build/qemu-tests", "#{System.system_time(:millisecond)}-#{System.pid()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    IO.puts("QEMU diagnostics: #{dir}")
    image = Path.join(dir, "gateway.img")
    on_exit(fn -> File.rm(image) end)

    command!("ip", ~w(link set lo up))
    command!("ip", ~w(tuntap add dev ng-test mode tap))
    on_exit(fn -> command!("ip", ~w(link delete ng-test)) end)
    command!("ip", ~w(addr add 192.168.77.1/24 dev ng-test))
    command!("ip", ~w(link set ng-test up))

    command!("fwup", [
      "-q",
      "-a",
      "-i",
      "_build/x86_64_dev/nerves/images/nerves_gate.fw",
      "-d",
      image,
      "-t",
      "complete"
    ])

    daemon!(:epmd, "epmd", [], dir)

    poll(dir, "epmd", deadline(5_000), fn ->
      case :gen_tcp.connect({127, 0, 0, 1}, 4369, [:binary, active: false], 500) do
        {:ok, socket} ->
          :gen_tcp.close(socket)
          true

        _ ->
          false
      end
    end)

    {:ok, _} = Node.start(:"gateway_test@192.168.77.1", name_domain: :longnames)
    Node.set_cookie(:mycookie)
    on_exit(fn -> Node.stop() end)

    socket_path = Path.join(dir, "qmp.sock")

    daemon!(
      :qemu,
      "qemu-system-x86_64",
      [
        "-m",
        "1024",
        "-display",
        "none",
        "-monitor",
        "none",
        "-serial",
        "file:#{dir}/console.log",
        "-qmp",
        "unix:#{socket_path},server=on,wait=off",
        "-drive",
        "file=#{image},format=raw,if=virtio",
        "-netdev",
        "user,id=wan",
        "-device",
        "virtio-net-pci,netdev=wan,id=wan-nic",
        "-netdev",
        "user,id=equipment,net=10.0.3.0/24",
        "-device",
        "virtio-net-pci,netdev=equipment",
        "-netdev",
        "tap,id=management,ifname=ng-test,script=no,downscript=no",
        "-device",
        "virtio-net-pci,netdev=management"
      ],
      dir
    )

    poll(dir, "QMP socket", deadline(10_000), fn -> File.exists?(socket_path) end)

    {:ok, socket} =
      :gen_tcp.connect({:local, socket_path}, 0, [:binary, packet: :line, active: false], 2_000)

    on_exit(fn -> :gen_tcp.close(socket) end)
    {:ok, greeting} = :gen_tcp.recv(socket, 0, 2_000)
    assert Map.has_key?(Jason.decode!(greeting), "QMP")
    vm = %{dir: dir, socket: socket}
    qmp!(vm, "qmp_capabilities", %{})
    status = await(vm, "boot", & &1, 100_000)
    assert status.system.target == "x86_64"
    assert status.system.node == @guest
    vm
  end

  def disconnect_wan(vm), do: qmp!(vm, "set_link", %{name: "wan-nic", up: false})
  def reconnect_wan(vm), do: qmp!(vm, "set_link", %{name: "wan-nic", up: true})

  # A hard reset, using the same disk. Management and QMP are never faulted.
  def reboot(vm) do
    qmp!(vm, "system_reset", %{})
    # A hard reset cannot close the old TCP session cleanly. Reconnect explicitly
    # rather than waiting for OTP's distribution heartbeat to expire.
    Node.disconnect(@guest)
    await(vm, "boot after reset", & &1, 100_000)
  end

  def call(vm, function, args) do
    result = :erpc.call(@guest, NervesGate, function, args, 15_000)
    log(vm.dir, "api.log", {function, result})
    if match?({:error, _}, result), do: capture_logs(vm)
    result
  end

  def status(vm) do
    status = :erpc.call(@guest, NervesGate, :status, [], 2_000)
    log(vm.dir, "snapshots.log", status)
    status
  catch
    :error, {:erpc, reason} ->
      log(vm.dir, "snapshots.log", {:unavailable, reason})
      nil
  end

  def await(vm, phase, predicate, timeout \\ 30_000) do
    poll(vm.dir, phase, deadline(timeout), fn ->
      status = status(vm)
      if status && predicate.(status), do: status
    end)
  end

  defp daemon!(id, executable, args, dir) do
    spec =
      Supervisor.child_spec(
        {MuonTrap.Daemon,
         [
           executable,
           args,
           [
             stderr_to_stdout: true,
             logger_fun: fn line ->
               File.write!(Path.join(dir, "#{id}.log"), line <> "\n", [:append])
             end
           ]
         ]},
        id: id,
        restart: :temporary
      )

    start_supervised!(spec)
  end

  defp command!(executable, args) do
    {output, status} = System.cmd(executable, args, stderr_to_stdout: true)
    assert status == 0, "#{executable} failed: #{output}"
  end

  defp capture_logs(vm) do
    log(vm.dir, "guest.log", :erpc.call(@guest, RingLogger, :get, [], 2_000))
  catch
    kind, reason -> log(vm.dir, "guest.log", {kind, reason})
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout

  defp poll(dir, phase, deadline, check) do
    value = check.()
    log(dir, "phases.log", {phase, !!value})

    cond do
      value ->
        value

      System.monotonic_time(:millisecond) >= deadline ->
        flunk("Timed out: #{phase}; diagnostics: #{dir}")

      true ->
        Process.sleep(500)
        poll(dir, phase, deadline, check)
    end
  end

  defp log(dir, file, value) do
    File.write!(
      Path.join(dir, file),
      "#{System.system_time(:millisecond)} #{inspect(value, limit: :infinity)}\n",
      [:append]
    )
  end

  defp qmp!(vm, command, arguments) do
    id = System.unique_integer([:positive])
    request = Jason.encode!(%{execute: command, arguments: arguments, id: id})
    log(vm.dir, "qmp.log", {:send, request})
    :ok = :gen_tcp.send(vm.socket, request <> "\r\n")
    reply!(vm, id, deadline(3_000))
  end

  defp reply!(vm, id, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    {:ok, line} = :gen_tcp.recv(vm.socket, 0, remaining)
    log(vm.dir, "qmp.log", {:recv, line})

    case Jason.decode!(line) do
      %{"id" => ^id, "return" => value} ->
        value

      %{"id" => ^id, "error" => error} ->
        flunk("QMP failed: #{inspect(error)}")

      _ ->
        assert remaining > 0, "QMP reply timed out"
        reply!(vm, id, deadline)
    end
  end
end

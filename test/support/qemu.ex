defmodule NervesGate.TestQemu do
  @moduledoc "Test-only controls for an owned QEMU, never a physical device."
  import ExUnit.Assertions
  alias NervesGate.TestNetwork

  @guest :"nerves_gate@127.0.0.1"

  def guest, do: @guest

  def start(options \\ []) do
    System.fetch_env!("QEMU_HTTP_SOCKET")

    if Node.alive?() do
      raise "The bench requires its own controller VM"
    end

    {:ok, _} = Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Supervisor)
    dir = Path.join("_build/qemu-tests", "#{System.system_time(:millisecond)}-#{System.pid()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 448)
    IO.puts("QEMU diagnostics: #{dir}")
    {:ok, _} = Supervisor.start_child(__MODULE__.Supervisor, {TestNetwork, dir})
    image = Path.join(dir, "gateway.img")
    on_exit(fn -> File.rm(image) end)
    forwards = forward_ports!()
    {:ok, _} = Node.start(:"gateway_test@127.0.0.1", name_domain: :longnames, dist_listen: false)
    Node.set_cookie(:mycookie)
    on_exit(fn -> Node.stop() end)
    create_image(image)
    boot_vm(dir, image, forwards, options)
  end

  defp boot_vm(dir, image, forwards, options) do
    socket_path = Path.join(dir, "qmp.sock")

    for socket <- Path.wildcard(Path.join(dir, "*.sock")) do
      File.rm!(socket)
    end

    boot = System.unique_integer([:positive])

    stall =
      if options[:receive_stall] do
        "on"
      else
        "off"
      end

    daemon =
      daemon!(
        :qemu,
        "qemu-system-x86_64",
        [
          "-S",
          "-m",
          "1024",
          "-display",
          "none",
          "-monitor",
          "none",
          "-serial",
          "file:#{dir}/console-#{boot}.log",
          "-pidfile",
          "#{dir}/qemu.pid",
          "-qmp",
          "unix:#{socket_path},server=on,wait=off",
          "-blockdev",
          "driver=file,node-name=storage,filename=#{image}",
          "-blockdev",
          "driver=raw,node-name=disk,file=storage",
          "-device",
          "virtio-blk-pci,drive=disk,werror=report,rerror=report"
        ] ++
          TestNetwork.arguments(dir, forwards, options[:usb] || false) ++
          [
            "-object",
            "filter-buffer,id=lan1-stall,netdev=lan1,queue=tx,interval=3600000000,status=#{stall}"
          ],
        dir
      )

    poll(dir, "QMP socket", deadline(10_000), fn ->
      unless Process.alive?(daemon) do
        raise "QEMU exited; inspect #{dir}/qemu.log"
      end

      File.exists?(socket_path)
    end)

    {:ok, socket} =
      :gen_tcp.connect({:local, socket_path}, 0, [:binary, packet: :line, active: false], 2000)

    {:ok, greeting} = :gen_tcp.recv(socket, 0, 2000)
    assert Map.has_key?(Jason.decode!(greeting), "QMP")
    pid = dir |> Path.join("qemu.pid") |> File.read!() |> String.trim() |> String.to_integer()

    vm = %{
      dir: dir,
      socket: socket,
      daemon: daemon,
      pid: pid,
      forwards: forwards,
      options: options
    }

    Process.put(:qemu_vm, vm)
    qmp!(vm, "qmp_capabilities", %{})
    :ok = TestNetwork.attach()
    apply_cables(vm, network(vm).cables)
    :ok = TestNetwork.release()

    for key <- ~w(vm lan1_device disk) do
      fault(key, nil)
    end

    fault(
      "receive",
      if options[:receive_stall] do
        "LAN1 receive stalled"
      end
    )

    report_network()
    qmp!(vm, "cont", %{})
    status = await(vm, "boot", & &1, 180_000)
    assert status.system.target == "x86_64"
    assert status.system.node == @guest
    vm
  end

  # Keep all ports reserved while choosing them. QEMU's actual bind remains
  # authoritative; a race fails startup rather than touching another listener.
  defp forward_ports! do
    epmd_port = System.fetch_env!("ERL_EPMD_PORT") |> String.to_integer()

    unless :init.get_argument(:epmd_port) == {:ok, [[Integer.to_charlist(epmd_port)]]} do
      raise "The controller must start with its session EPMD port. Use mix dev.qemu."
    end

    sockets =
      for {name, port} <- [distribution: 9100, epmd: epmd_port, http: 0, ssh: 0, usb: 0] do
        case :gen_tcp.listen(port, ip: {127, 0, 0, 1}, reuseaddr: true) do
          {:ok, socket} ->
            {name, socket}

          {:error, reason} ->
            raise "Cannot reserve QEMU loopback TCP port #{port}: #{inspect(reason)}"
        end
      end

    try do
      Map.new(sockets, fn {name, socket} ->
        {:ok, port} = :inet.port(socket)
        {name, port}
      end)
    after
      for {_, socket} <- sockets do
        :gen_tcp.close(socket)
      end
    end
  end

  def connect_usb(vm) do
    owned!()
    assert status(vm).system.target == "x86_64"
    {_, 0} = :erpc.call(@guest, System, :cmd, ["ip", ~w"link set eth3 down"])
    {_, 0} = :erpc.call(@guest, System, :cmd, ["ip", ~w"link set eth3 name usb0"])

    :ok =
      :erpc.call(@guest, VintageNet, :configure, [
        "usb0",
        %{
          type: VintageNetEthernet,
          ipv4: %{method: :static, address: "172.31.255.1", prefix_length: 30}
        },
        [persist: false]
      ])

    await(vm, "USB test Ethernet path", fn status ->
      status.network.observed.usb.link and
        Enum.any?(status.network.observed.usb.addresses, &(&1.address == "172.31.255.1"))
    end)
  end

  # QEMU TX is backend-to-guest traffic; turning the filter off flushes its buffer.
  def release_lan1_receive(vm) do
    assert "tx" == qmp!(vm, "qom-get", %{path: "/objects/lan1-stall", property: "queue"})
    assert "on" == qmp!(vm, "qom-get", %{path: "/objects/lan1-stall", property: "status"})
    qmp!(vm, "qom-set", %{path: "/objects/lan1-stall", property: "status", value: "off"})
    fault("receive", nil)
  end

  def network(_vm), do: TestNetwork.snapshot().config
  def topology, do: TestNetwork.connections(TestNetwork.snapshot().config.internet)
  def network_stats, do: TestNetwork.snapshot().stats

  @doc "Apply a partial network map. Omitted cables and uplink settings are preserved."
  def network(vm, patch) do
    owned!()
    on_exit(:network, fn -> network(current() || vm, TestNetwork.defaults()) end)

    case TestNetwork.configure(patch) do
      {:error, reason} ->
        {:error, reason}

      {:ok, previous, config} ->
        if previous.internet != config.internet do
          unplug(vm)
        end

        if previous.cables != config.cables or not TestNetwork.snapshot().ready do
          apply_cables(vm, config.cables)
        end

        :ok = TestNetwork.release()
        report_network()
        log(vm.dir, "faults.log", {:network, config, network_stats()})
        :ok
    end
  end

  defp unplug(vm) do
    for port <- [:lan1, :lan2] do
      link(vm, port, false)
    end

    if qmp!(vm, "query-status", %{})["running"] do
      await(
        vm,
        "Cables unplugged for topology change",
        fn status -> Enum.all?(status.connections.ports, &(!&1.link)) end,
        5000
      )
    end
  end

  # Used only after the relay's monitor reports failure. No new traffic can pass
  # a dead relay, and we also stop the VM rather than leave a partial bench alive.
  def stop_owned do
    Supervisor.terminate_child(__MODULE__.Supervisor, :qemu)
  end

  def remove_lan1(vm) do
    qmp!(vm, "device_del", %{id: "lan1-nic"})
    fault("lan1_device", "LAN1 NIC removed")
  end

  def insert_lan1(vm) do
    devices = qmp!(vm, "qom-list", %{path: "/machine/peripheral"})

    unless Enum.any?(devices, &(&1["name"] == "lan1-nic")) do
      qmp!(vm, "device_add", %{
        driver: "virtio-net-pci",
        netdev: "lan1",
        id: "lan1-nic",
        mac: "52:54:00:12:34:56"
      })
    end

    link(vm, :lan1, network(vm).cables.lan1)
    fault("lan1_device", nil)
  end

  def fail_disk_writes(vm) do
    qmp!(vm, "blockdev-add", %{
      driver: "blkdebug",
      "node-name": "write-fault",
      image: "storage",
      "inject-error": [
        %{event: "write_aio", iotype: "write", errno: 5, immediately: true, once: false}
      ]
    })

    qmp!(vm, "blockdev-reopen", %{
      options: [%{"node-name": "disk", driver: "raw", file: "write-fault"}]
    })

    log(vm.dir, "faults.log", :disk_write_eio_enabled)
    fault("disk", "Disk writes return EIO")
  end

  def restore_disk_writes(vm) do
    owned!()
    log(vm.dir, "faults.log", qmp!(vm, "query-blockstats", %{}))

    qmp!(vm, "blockdev-reopen", %{
      options: [%{"node-name": "disk", driver: "raw", file: "storage"}]
    })

    qmp!(vm, "blockdev-del", %{"node-name": "write-fault"})
    log(vm.dir, "faults.log", :disk_write_eio_removed)
    fault("disk", nil)
  end

  def failed_disk_writes(vm) do
    Enum.sum(
      Enum.reject(
        Enum.map(
          qmp!(vm, "query-blockstats", %{}),
          &get_in(&1, ["stats", "failed_wr_operations"])
        ),
        &is_nil/1
      )
    )
  end

  def pause(vm) do
    qmp!(vm, "stop", %{})
    on_exit(:pause, fn -> resume(current() || vm) end)
    fault("vm", "VM paused")
  end

  def resume(vm) do
    qmp!(vm, "cont", %{})
    on_exit(:pause, fn -> :ok end)
    fault("vm", nil)
  end

  # A hard reset, using the same disk. Management and QMP are never faulted.
  def reboot(vm) do
    qmp!(vm, "system_reset", %{})
    # Drop the stale TCP session rather than waiting for OTP's heartbeat timeout.
    Node.disconnect(@guest)
    await(vm, "boot after reset", & &1, 100_000)
  end

  def power_cycle(vm) do
    owned_vm!(vm)
    :ok = TestNetwork.detach()
    IO.puts("QEMU fault injection: intentional SIGKILL (power cycle)")
    log(vm.dir, "faults.log", :qemu_power_cut_requested)
    ref = Process.monitor(vm.daemon)
    # Hold the exit-status handler only for this intentional kill, then stop the
    # daemon normally. Unexpected exits elsewhere still produce crash reports.
    :ok = :sys.suspend(vm.daemon)

    try do
      command!("kill", ["-KILL", to_string(vm.pid)])

      poll(vm.dir, "QEMU power cut", deadline(5000), fn -> not File.exists?("/proc/#{vm.pid}") end)

      stop_supervised(:qemu)
      assert_receive {:DOWN, ^ref, :process, _, :shutdown}, 5000
    after
      if Process.alive?(vm.daemon), do: :sys.resume(vm.daemon)
      Process.demonitor(ref, [:flush])
    end

    :gen_tcp.close(vm.socket)
    Node.disconnect(@guest)
    assert status(vm) == nil
    log(vm.dir, "faults.log", :qemu_process_killed)
    boot_vm(vm.dir, Path.join(vm.dir, "gateway.img"), vm.forwards, vm.options)
  end

  # Read-only kernel/userspace compatibility check, independent of enrollment.
  def check_firewall(vm) do
    owned!()

    for tool <- ~w(iptables ip6tables), table <- ~w(filter nat mangle) do
      {output, status} =
        :erpc.call(
          @guest,
          System,
          :cmd,
          ["/usr/sbin/#{tool}", ["--wait", "5", "-t", table, "-S"], [stderr_to_stdout: true]],
          10_000
        )

      log(vm.dir, "firewall.log", {tool, table, status})
      assert status == 0, "Guest #{tool} #{table} table unavailable: #{output}"
      if table == "nat", do: assert(output =~ "-P POSTROUTING ")
    end

    :ok
  end

  # Run on the guest, not the workstation. No mock DNS, proxy or TLS bypass.
  def internet_request(vm, timeout \\ 15_000) do
    owned!()
    # httpc verifies TLS by default and loads the guest's CA store locally.

    result =
      :erpc.call(
        @guest,
        :httpc,
        :request,
        [
          :get,
          {~c"https://example.com/", [{~c"connection", ~c"close"}]},
          [
            timeout: timeout,
            connect_timeout: timeout,
            autoredirect: false
          ],
          [body_format: :binary]
        ],
        timeout + 5_000
      )

    result =
      case result do
        {:ok, {{_, status, _}, _, _}} -> {:ok, status}
        {:error, reason} -> {:error, reason}
      end

    log(vm.dir, "internet.log", result)
    result
  end

  # Never send a private login URL through call/3, assertions or diagnostics.
  def login_ready? do
    owned!()

    match?({:ok, "https://" <> _}, :erpc.call(@guest, NervesGate, :remote_login_url, [], 2_000))
  end

  def call(vm, function, args) do
    owned!()
    result = :erpc.call(@guest, NervesGate, function, args, 15_000)
    log(vm.dir, "api.log", {function, result})

    if match?({:error, _}, result) do
      capture_logs(vm)
    end

    result
  end

  def status(vm) do
    owned!()
    status = :erpc.call(@guest, NervesGate, :status, [], 2_000)
    log(vm.dir, "snapshots.log", status)
    status
  catch
    :error, {:erpc, reason} ->
      log(vm.dir, "snapshots.log", {:unavailable, reason})
      nil
  end

  def await(vm, phase, predicate, timeout \\ 30_000) do
    if report = Process.get(:qemu_report), do: report.(phase)

    poll(vm.dir, phase, deadline(timeout), fn ->
      status = status(vm)

      if status && predicate.(status) do
        status
      end
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

    {:ok, pid} = Supervisor.start_child(__MODULE__.Supervisor, spec)
    pid
  end

  def current, do: Process.get(:qemu_vm)
  def adopt(vm), do: Process.put(:qemu_vm, vm)

  def fresh(vm, options \\ []) do
    owned_vm!(vm)
    :ok = TestNetwork.detach()
    stop_supervised(:qemu)
    # The daemon exits before its OS child finishes releasing the image and PID file.
    poll(vm.dir, "QEMU stopped", deadline(5_000), fn ->
      not File.exists?("/proc/#{vm.pid}")
    end)

    :gen_tcp.close(vm.socket)
    Node.disconnect(@guest)
    image = Path.join(vm.dir, "gateway.img")
    File.rm!(image)
    create_image(image)
    {:ok, _, _} = TestNetwork.configure(TestNetwork.defaults())
    boot_vm(vm.dir, image, vm.forwards, options)
  end

  def cleanup do
    # Resume first even if another fault was injected after Pause. Restoration
    # may need the guest to acknowledge a cable transition.
    callbacks =
      (Process.delete(:qemu_cleanup) || [])
      |> Enum.sort_by(fn {id, _} -> if id == :pause, do: 0, else: 1 end)

    errors =
      for {_, callback} <- callbacks, reduce: [] do
        errors ->
          try do
            callback.()
            errors
          rescue
            error -> [error | errors]
          end
      end

    Process.delete(:qemu_cleanup)
    if errors != [], do: raise("Fault cleanup failed: #{inspect(errors)}; restart mix dev.qemu")
  end

  defp on_exit(callback) do
    on_exit(make_ref(), callback)
  end

  defp on_exit(id, callback) do
    callbacks = Process.get(:qemu_cleanup, [])
    Process.put(:qemu_cleanup, [{id, callback} | List.keydelete(callbacks, id, 0)])
  end

  defp stop_supervised(id) do
    Supervisor.terminate_child(__MODULE__.Supervisor, id)
    Supervisor.delete_child(__MODULE__.Supervisor, id)
  end

  defp create_image(image) do
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
  end

  defp owned! do
    unless Process.whereis(__MODULE__.Supervisor) && Process.whereis(TestNetwork),
      do: raise("No owned QEMU session")
  end

  defp owned_vm!(vm) do
    owned!()

    assert Enum.any?(Supervisor.which_children(__MODULE__.Supervisor), fn
             {:qemu, pid, _, _} -> pid == vm.daemon
             _ -> false
           end)

    wrapper = MuonTrap.Daemon.os_pid(vm.daemon)
    status = File.read!("/proc/#{vm.pid}/status")
    assert Regex.match?(~r/^PPid:\s+#{wrapper}$/m, status), "QEMU process ownership changed"
  end

  defp command!(executable, args) do
    owned!()
    {output, status} = System.cmd(executable, args, stderr_to_stdout: true)
    assert status == 0, "#{executable} failed: #{output}"
    output
  end

  defp capture_logs(vm) do
    log(vm.dir, "guest.log", :erpc.call(@guest, RingLogger, :get, [], 2_000))
  catch
    kind, reason -> log(vm.dir, "guest.log", {kind, reason})
  end

  defp deadline(timeout) do
    System.monotonic_time(:millisecond) + timeout
  end

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

  defp apply_cables(vm, cables) do
    for {port, up} <- cables do
      link(vm, port, up)
    end
  end

  defp link(vm, port, up) do
    qmp!(vm, "set_link", %{name: "#{port}-nic", up: up})
  end

  defp cable_fault(port, up) do
    fault(
      to_string(port),
      if !up do
        "#{String.upcase(to_string(port))} cable disconnected"
      end
    )
  end

  defp report_network do
    config = TestNetwork.snapshot().config
    for {port, up} <- config.cables, do: cable_fault(port, up)

    fault(
      "latency",
      if(config.uplink.delay_ms > 0, do: "Uplink delay +#{config.uplink.delay_ms} ms")
    )

    fault(
      "internet",
      %{none: nil, alternate: "Uplink packet loss 50%", all: "Internet outage"}[
        config.uplink.loss
      ]
    )

    if report = Process.get(:qemu_topology), do: report.(topology())
  end

  defp fault(key, label) do
    if report = Process.get(:qemu_fault) do
      report.(key, label)
    end

    :ok
  end

  defp qmp!(vm, command, arguments) do
    owned_vm!(vm)
    id = System.unique_integer([:positive])
    request = Jason.encode!(%{execute: command, arguments: arguments, id: id})
    log(vm.dir, "qmp.log", {:send, request})
    :ok = :gen_tcp.send(vm.socket, request <> "\r\n")
    reply!(vm, id, deadline(3000))
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

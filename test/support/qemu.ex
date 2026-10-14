defmodule NervesGate.TestQemu do
  @moduledoc "Test-only controls for an owned QEMU, never a physical device."
  import ExUnit.Assertions

  @guest :"nerves_gate@192.168.77.2"

  def start(options \\ []) do
    isolated!()
    {:ok, _} = Supervisor.start_link([], strategy: :one_for_one, name: __MODULE__.Supervisor)
    dir = Path.join("_build/qemu-tests", "#{System.system_time(:millisecond)}-#{System.pid()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 448)
    IO.puts("QEMU diagnostics: #{dir}")
    image = Path.join(dir, "gateway.img")
    on_exit(fn -> File.rm(image) end)
    command!("ip", ~w"link set lo up")
    command!("ip", ~w"tuntap add dev ng-test mode tap")
    on_exit(fn -> command!("ip", ~w"link delete ng-test") end)
    command!("ip", ~w"addr add 192.168.77.1/24 dev ng-test")
    command!("ip", ~w"link set ng-test up")

    create_image(image)

    daemon!(:epmd, "epmd", [], dir)

    poll(dir, "epmd", deadline(5000), fn ->
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
    boot_vm(dir, image, options)
  end

  defp boot_vm(dir, image, options \\ []) do
    socket_path = Path.join(dir, "qmp.sock")
    File.rm(socket_path)
    boot = System.unique_integer([:positive])
    stall = if options[:receive_stall], do: "on", else: "off"

    daemon =
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
          "virtio-blk-pci,drive=disk,werror=report,rerror=report",
          "-netdev",
          "user,id=wan",
          "-device",
          "virtio-net-pci,netdev=wan,id=wan-nic,mac=52:54:00:12:34:56",
          "-netdev",
          "user,id=equipment,net=10.0.3.0/24",
          "-device",
          "virtio-net-pci,netdev=equipment,id=equipment-nic",
          "-netdev",
          "tap,id=management,ifname=ng-test,script=no,downscript=no",
          "-device",
          "virtio-net-pci,netdev=management",
          "-object",
          "filter-buffer,id=wan-stall,netdev=wan,queue=tx,interval=3600000000,status=#{stall}"
        ],
        dir
      )

    poll(dir, "QMP socket", deadline(10_000), fn -> File.exists?(socket_path) end)

    {:ok, socket} =
      :gen_tcp.connect({:local, socket_path}, 0, [:binary, packet: :line, active: false], 2_000)

    {:ok, greeting} = :gen_tcp.recv(socket, 0, 2_000)
    assert Map.has_key?(Jason.decode!(greeting), "QMP")
    pid = dir |> Path.join("qemu.pid") |> File.read!() |> String.trim() |> String.to_integer()
    vm = %{dir: dir, socket: socket, daemon: daemon, pid: pid}
    Process.put(:qemu_vm, vm)
    qmp!(vm, "qmp_capabilities", %{})
    status = await(vm, "boot", & &1, 100_000)
    assert status.system.target == "x86_64"
    assert status.system.node == @guest
    vm
  end

  # QEMU TX is backend-to-guest traffic; turning the filter off flushes its buffer.
  def release_wan_receive(vm) do
    assert "tx" == qmp!(vm, "qom-get", %{path: "/objects/wan-stall", property: "queue"})
    assert "on" == qmp!(vm, "qom-get", %{path: "/objects/wan-stall", property: "status"})
    qmp!(vm, "qom-set", %{path: "/objects/wan-stall", property: "status", value: "off"})
  end

  def start_internet_faults(vm) do
    command!("nft", ["add", "table", "inet", "ng_faults"])
    on_exit(fn -> command!("nft", ~w"delete table inet ng_faults") end)

    command!("nft", [
      "add",
      "chain",
      "inet",
      "ng_faults",
      "outage",
      "{ type filter hook output priority 0; policy accept; }"
    ])

    log(vm.dir, "faults.log", :internet_faults_ready)
  end

  def delay_internet(vm) do
    command!("tc", ~w"qdisc add dev ng-uplink root netem delay 200ms")
    on_exit(:netem, fn -> command!("tc", ~w"qdisc del dev ng-uplink root") end)
    log(vm.dir, "faults.log", :internet_delayed_200ms)
  end

  def clear_delay(vm) do
    isolated!()
    {stats, 0} = System.cmd("tc", ~w"-s qdisc show dev ng-uplink")
    log(vm.dir, "faults.log", stats)
    command!("tc", ~w"qdisc del dev ng-uplink root")
    on_exit(:netem, fn -> :ok end)
  end

  def drop_internet(vm) do
    command!("nft", [
      "add",
      "rule",
      "inet",
      "ng_faults",
      "outage",
      "oifname",
      "\"ng-uplink\"",
      "counter",
      "drop"
    ])

    log(vm.dir, "faults.log", :internet_dropped)
  end

  def lose_internet_packets(vm) do
    command!("nft", [
      "add",
      "rule",
      "inet",
      "ng_faults",
      "outage",
      "oifname",
      "\"ng-uplink\"",
      "numgen",
      "inc",
      "mod",
      "2",
      "==",
      "0",
      "counter",
      "drop"
    ])

    log(vm.dir, "faults.log", :every_other_uplink_packet_dropped)
  end

  def dropped_packets(vm) do
    %{"nftables" => entries} = Jason.decode!(command!("nft", ~w"-j list table inet ng_faults"))

    total =
      for %{"rule" => %{"expr" => expressions}} <- entries,
          %{"counter" => %{"packets" => packets}} <- expressions,
          reduce: 0 do
        total -> total + packets
      end

    log(vm.dir, "faults.log", {:dropped_packets, total})
    total
  end

  def restore_internet(vm) do
    isolated!()
    {rules, 0} = System.cmd("nft", ~w"list table inet ng_faults")
    log(vm.dir, "faults.log", rules)
    command!("nft", ~w"flush chain inet ng_faults outage")
    log(vm.dir, "faults.log", :internet_restored)
  end

  def disconnect_wan(vm) do
    qmp!(vm, "set_link", %{name: "wan-nic", up: false})
  end

  def reconnect_wan(vm) do
    qmp!(vm, "set_link", %{name: "wan-nic", up: true})
  end

  def disconnect_equipment(vm) do
    qmp!(vm, "set_link", %{name: "equipment-nic", up: false})
  end

  def reconnect_equipment(vm) do
    qmp!(vm, "set_link", %{name: "equipment-nic", up: true})
  end

  def unplug_wan(vm) do
    qmp!(vm, "device_del", %{id: "wan-nic"})
  end

  def plug_wan(vm) do
    devices = qmp!(vm, "qom-list", %{path: "/machine/peripheral"})

    unless Enum.any?(devices, &(&1["name"] == "wan-nic")) do
      qmp!(vm, "device_add", %{
        driver: "virtio-net-pci",
        netdev: "wan",
        id: "wan-nic",
        mac: "52:54:00:12:34:56"
      })
    end
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
  end

  def restore_disk_writes(vm) do
    isolated!()
    log(vm.dir, "faults.log", qmp!(vm, "query-blockstats", %{}))

    qmp!(vm, "blockdev-reopen", %{
      options: [%{"node-name": "disk", driver: "raw", file: "storage"}]
    })

    qmp!(vm, "blockdev-del", %{"node-name": "write-fault"})
    log(vm.dir, "faults.log", :disk_write_eio_removed)
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
  end

  def resume(vm) do
    qmp!(vm, "cont", %{})
  end

  # A hard reset, using the same disk. Management and QMP are never faulted.
  def reboot(vm) do
    qmp!(vm, "system_reset", %{})
    # Drop the stale TCP session rather than waiting for OTP's heartbeat timeout.
    Node.disconnect(@guest)
    await(vm, "boot after reset", & &1, 100_000)
  end

  def power_cycle(vm) do
    isolated!()
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
    boot_vm(vm.dir, Path.join(vm.dir, "gateway.img"))
  end

  # Read-only kernel/userspace compatibility check, independent of enrollment.
  def check_firewall(vm) do
    isolated!()

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
    isolated!()
    ssl = :erpc.call(@guest, :httpc, :ssl_verify_host_options, [true], 2_000)

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
            autoredirect: false,
            ssl: ssl
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
    isolated!()

    match?({:ok, "https://" <> _}, :erpc.call(@guest, NervesGate, :remote_login_url, [], 2_000))
  end

  def call(vm, function, args) do
    isolated!()
    result = :erpc.call(@guest, NervesGate, function, args, 15_000)
    log(vm.dir, "api.log", {function, result})

    if match?({:error, _}, result) do
      capture_logs(vm)
    end

    result
  end

  def status(vm) do
    isolated!()
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
    isolated!()
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
    boot_vm(vm.dir, image, options)
  end

  def cleanup do
    callbacks = Process.delete(:qemu_cleanup) || []

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

    if errors != [], do: raise("Fault cleanup failed: #{inspect(errors)}; restart mix dev.qemu")
  end

  defp on_exit(callback), do: on_exit(make_ref(), callback)

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

  defp isolated! do
    if File.read_link!("/proc/self/ns/net") == System.fetch_env!("NERVES_GATE_HOST_NETNS"),
      do: raise("Refusing to fault networking in the workstation namespace")
  end

  defp command!(executable, args) do
    isolated!()
    {output, status} = System.cmd(executable, args, stderr_to_stdout: true)
    assert status == 0, "#{executable} failed: #{output}"
    output
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
    isolated!()
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

defmodule Simulator.Device do
  @moduledoc false
  use GenServer
  alias Simulator.{Network, Qemu, SSH}

  def start_link(config), do: GenServer.start_link(__MODULE__, config)
  def handle(pid), do: GenServer.call(pid, :handle, 480_000)

  @impl true
  def init(config) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(config.dir)
    File.chmod!(config.dir, 0o700)
    {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)
    {:ok, network} = Supervisor.start_child(supervisor, {Network, config.dir})
    {:ok, _, initial_network} = Network.configure(network, Map.get(config, :network, %{}))
    network_monitor = Process.monitor(network)
    usb = usb(config.serial)

    vm =
      Map.merge(config, %{
        supervisor: supervisor,
        network: network,
        network_monitor: network_monitor,
        initial_network: initial_network,
        usb: usb,
        options: [],
        forwards: forward_ports(config.address),
        owner: self(),
        daemon_monitor: nil,
        boot_worker: nil,
        waiters: []
      })

    {:ok, Map.put(vm, :existing_disk, File.regular?(Qemu.image_path(vm))), {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, vm), do: {:noreply, start_boot(vm, :boot, nil)}

  @impl true
  def handle_call(:handle, from, %{boot_worker: worker} = vm) when not is_nil(worker),
    do: {:noreply, %{vm | waiters: [from | vm.waiters]}}

  def handle_call(:handle, _, vm), do: {:reply, public_handle(vm), vm}

  def handle_call({:command, _, _}, _, %{boot_worker: worker} = vm) when not is_nil(worker),
    do: {:reply, {:error, :device_starting}, vm}

  def handle_call({:command, :observe, []}, _, vm) do
    {:reply, Network.snapshot(vm.network), vm}
  end

  def handle_call({:command, :network, [patch]}, _, vm),
    do: {:reply, Qemu.network(vm, patch), vm}

  def handle_call({:command, :fresh, [options]}, from, vm) do
    Process.demonitor(vm.daemon_monitor, [:flush])
    {:noreply, start_boot(vm, {:fresh, options}, from)}
  end

  def handle_call({:command, :power_cycle, []}, _, vm) do
    Process.demonitor(vm.daemon_monitor, [:flush])
    vm = vm |> Qemu.power_cycle() |> monitor()
    {:reply, :ok, vm}
  end

  def handle_call({:command, command, []}, _, vm)
      when command in [
             :pause,
             :resume,
             :reboot,
             :remove_lan1,
             :insert_lan1,
             :fail_disk_writes,
             :restore_disk_writes,
             :failed_disk_writes,
             :release_lan1_receive
           ] do
    {:reply, apply(Qemu, command, [vm]), vm}
  end

  @impl true
  def handle_info({:booted, worker, booted, caller}, %{boot_worker: worker} = vm) do
    Process.unlink(worker)
    for from <- vm.waiters, do: GenServer.reply(from, public_handle(booted))
    if caller, do: GenServer.reply(caller, :ok)
    report(booted, "Ready")
    {:noreply, monitor(%{booted | boot_worker: nil, waiters: []})}
  end

  def handle_info({:EXIT, worker, _}, %{boot_worker: worker} = vm),
    do: {:stop, :device_bootstrap_failed, vm}

  def handle_info({:DOWN, ref, :process, _, _}, vm)
      when ref == vm.network_monitor or ref == vm.daemon_monitor,
      do: {:stop, :device_transport_failed, vm}

  def handle_info({:EXIT, supervisor, _}, %{supervisor: supervisor} = vm),
    do: {:stop, :device_supervisor_failed, vm}

  def handle_info({:EXIT, _, :normal}, vm), do: {:noreply, vm}

  # Device failure stops its supervisor and the whole simulator. No restart can
  # silently erase the disk/fault state or turn an unknown outcome into success.
  @impl true
  def terminate(_, vm) do
    if vm.boot_worker do
      Process.unlink(vm.boot_worker)
      ref = Process.monitor(vm.boot_worker)
      Process.exit(vm.boot_worker, :kill)

      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      end
    end

    if Process.alive?(vm.supervisor), do: Supervisor.stop(vm.supervisor, :normal)
    :ok
  end

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, Map.take(status.state, [:id, :node, :dir]))
    |> Map.replace(:message, :redacted)
    |> Map.replace(:reason, :device_failed)
    |> Map.replace(:log, [])
  end

  defp start_boot(vm, operation, caller) do
    owner = self()

    # Boot and fresh-disk update share one isolated transport worker. In
    # particular, late SSH channel messages must never enter the owner's inbox.
    worker =
      spawn_link(fn ->
        booted = boot(vm, operation)
        :ok = :gen_tcp.controlling_process(booted.socket, owner)
        send(owner, {:booted, self(), booted, caller})
      end)

    %{vm | boot_worker: worker}
  end

  defp boot(vm, :boot) do
    report(vm, "Booting #{if vm.existing_disk, do: "preserved", else: "factory"} disk")
    if vm.existing_disk, do: Qemu.boot(vm), else: vm |> Qemu.image() |> Qemu.boot() |> bootstrap()
  end

  defp boot(vm, {:fresh, options}), do: vm |> Qemu.fresh(options) |> bootstrap()

  defp public_handle(vm),
    do: Map.take(vm, [:id, :node, :address, :forwards, :usb, :owner, :dir, :firmware])

  defp monitor(vm), do: %{vm | daemon_monitor: Process.monitor(vm.daemon)}

  defp bootstrap(vm) do
    report(vm, "Factory boot ready; applying current firmware over USB SSH")
    connection = connect(vm)
    before = :erpc.call(vm.node, Nerves.Runtime.FwupOps, :status, [], 5000)
    {:ok, %{active: active}} = before
    next = if active == "a", do: "b", else: "a"

    try do
      :ok = SSH.upload(connection, vm.firmware)
    after
      :ssh.close(connection)
    end

    Qemu.poll(vm, "current firmware boot", 180_000, fn ->
      match?(
        {:ok, %{active: ^next, next: ^next}},
        :rpc.call(vm.node, Nerves.Runtime.FwupOps, :status, [], 2000)
      )
    end)

    Qemu.await_boot(vm)
    report(vm, "Current firmware booted; provisioning")
    connection = connect(vm)

    try do
      :ok = SSH.provision(connection, Map.get(vm, :provision, %{}))
    after
      :ssh.close(connection)
    end

    vm
  end

  defp report(%{progress: {owner, token}, id: id}, phase),
    do: send(owner, {:device_phase, token, id, phase})

  defp connect(vm) do
    Qemu.poll(vm, "USB recovery SSH", 90_000, fn ->
      case SSH.connect(vm, vm.forwards.usb,
             user: ~c"root",
             password: ~c"nerves_gate",
             auth_methods: ~c"password"
           ) do
        {:ok, connection} -> connection
        {:error, _} -> nil
      end
    end)
  end

  defp usb(serial) do
    {a, b, c, _} = subnet = OneDHCPD.IPCalculator.default_subnet("usb0", serial)

    %{
      network: "#{a}.#{b}.#{c}.0",
      device: subnet |> OneDHCPD.IPCalculator.our_ip_address() |> :inet.ntoa() |> to_string(),
      peer: subnet |> OneDHCPD.IPCalculator.their_ip_address() |> :inet.ntoa() |> to_string()
    }
  end

  # The gateway UI forward listens on 127.0.0.1, which VM hosts such as OrbStack
  # forward to the workstation. The others need the device's own address.
  defp forward_ports(address) do
    {:ok, ip} = :inet.parse_address(String.to_charlist(address))
    epmd = System.fetch_env!("ERL_EPMD_PORT") |> String.to_integer()

    sockets =
      for {name, ip, port} <- [
            {:epmd, ip, epmd},
            {:distribution, ip, 9100},
            {:http, {127, 0, 0, 1}, 0},
            {:ssh, ip, 0},
            {:usb, ip, 0}
          ] do
        {:ok, socket} = :gen_tcp.listen(port, ip: ip, reuseaddr: true)
        {name, socket}
      end

    try do
      Map.new(sockets, fn {name, socket} ->
        {:ok, port} = :inet.port(socket)
        {name, port}
      end)
    after
      for {_, socket} <- sockets, do: :gen_tcp.close(socket)
    end
  end
end

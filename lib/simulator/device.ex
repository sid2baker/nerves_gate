defmodule Simulator.Device do
  @moduledoc false
  use GenServer
  alias Simulator.{Network, Qemu}

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
    usb = Map.put(usb(config.serial), :port, recovery_port())

    vm =
      Map.merge(config, %{
        supervisor: supervisor,
        network: network,
        network_monitor: network_monitor,
        initial_network: initial_network,
        usb: usb,
        options: [],
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
    if vm.existing_disk, do: Qemu.boot(vm), else: vm |> Qemu.image() |> Qemu.boot() |> provision()
  end

  defp boot(vm, {:fresh, options}), do: vm |> Qemu.fresh(options) |> provision()

  defp public_handle(vm),
    do: Map.take(vm, [:id, :node, :address, :management_host, :usb, :owner, :dir, :firmware])

  defp monitor(vm), do: %{vm | daemon_monitor: Process.monitor(vm.daemon)}

  # The disk image already holds the current firmware; configure it over distribution.
  defp provision(vm) do
    config = Map.get(vm, :provision, %{})
    report(vm, "Booted; provisioning")

    for key <- Map.get(config, :ssh_keys, []),
        do: :ok = :erpc.call(vm.node, NervesGate.SSH, :add_key, [key], 10_000)

    if settings = config[:network] do
      await_action(vm, "network.propose")
      {:ok, trial} = :erpc.call(vm.node, NervesGate.Network, :propose, [settings], 10_000)
      await_action(vm, "network.confirm")
      :ok = :erpc.call(vm.node, NervesGate.Network, :confirm, [trial], 10_000)
    end

    vm
  end

  defp await_action(vm, action) do
    Qemu.poll(vm, action, 30_000, fn ->
      status = Qemu.status(vm)
      status && status.actions[action].enabled
    end)
  end

  defp report(%{progress: {owner, token}, id: id}, phase),
    do: send(owner, {:device_phase, token, id, phase})

  defp usb(serial) do
    {a, b, c, _} = subnet = OneDHCPD.IPCalculator.default_subnet("usb0", serial)

    %{
      network: "#{a}.#{b}.#{c}.0",
      device: subnet |> OneDHCPD.IPCalculator.our_ip_address() |> :inet.ntoa() |> to_string(),
      peer: subnet |> OneDHCPD.IPCalculator.their_ip_address() |> :inet.ntoa() |> to_string()
    }
  end

  # Only USB recovery has a loopback forward; normal services use the guest IP.
  defp recovery_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end
end

defmodule Scenarios.Qemu do
  @moduledoc "Scenario assertions and cleanup for simulator-owned device handles."
  import ExUnit.Assertions
  import Scenarios.Device, only: [await: 3, await: 4]
  alias Simulator.Network

  def capabilities(_vm), do: [:qemu, :ethernet_link, :reboot, :power_cycle]

  def control(vm, :ethernet_link, [interface, up]) when is_boolean(up) do
    case %{"eth0" => :lan1, "eth1" => :lan2}[interface] do
      nil -> {:error, :unsupported_fixture_control}
      port -> network(vm, %{cables: %{port => up}})
    end
  end

  def control(vm, :reboot, []), do: reboot(vm)
  def control(vm, :power_cycle, []), do: power_cycle(vm)
  def control(_, _, _), do: {:error, :unsupported_fixture_control}

  def network(vm), do: Simulator.observe(vm).config
  def topology(vm), do: Network.connections(network(vm).internet)
  def network_stats(vm), do: Simulator.observe(vm).stats

  def ui_url(vm), do: "http://#{vm.address}:4000"

  def network(vm, patch) do
    on_exit({vm.id, :network}, fn -> network(vm, Network.defaults()) end)
    result = Simulator.network(vm, patch)
    if result == :ok, do: report_network(vm)
    result
  end

  def connect_usb(vm) do
    await(vm, "VintageNetDirect USB recovery", fn status ->
      status.network.observed.usb.link and
        Enum.any?(status.network.observed.usb.addresses, &(&1.address == vm.usb.device))
    end)
  end

  def release_lan1_receive(vm) do
    :ok = Simulator.command(vm, :release_lan1_receive)
    fault(vm, "receive", nil)
  end

  def remove_lan1(vm) do
    :ok = Simulator.command(vm, :remove_lan1)
    fault(vm, "lan1_device", "LAN1 NIC removed")
  end

  def insert_lan1(vm) do
    :ok = Simulator.command(vm, :insert_lan1)
    fault(vm, "lan1_device", nil)
  end

  def fail_disk_writes(vm) do
    :ok = Simulator.command(vm, :fail_disk_writes)
    fault(vm, "disk", "Disk writes return EIO")
  end

  def restore_disk_writes(vm) do
    :ok = Simulator.command(vm, :restore_disk_writes)
    fault(vm, "disk", nil)
  end

  def failed_disk_writes(vm), do: Simulator.command(vm, :failed_disk_writes)

  def pause(vm) do
    Simulator.command(vm, :pause)
    on_exit({vm.id, :pause}, fn -> resume(vm) end)
    fault(vm, "vm", "VM paused")
  end

  def resume(vm) do
    Simulator.command(vm, :resume)
    on_exit({vm.id, :pause}, fn -> :ok end)
    fault(vm, "vm", nil)
  end

  def reboot(vm) do
    Simulator.command(vm, :reboot)
    Node.disconnect(vm.node)
    await(vm, "boot after reset", & &1, 180_000)
  end

  def power_cycle(vm) do
    :ok = Simulator.command(vm, :power_cycle)
    Node.disconnect(vm.node)
    await(vm, "boot after power cut", & &1, 180_000)
    vm
  end

  def fresh(vm, options \\ []) do
    :ok = Simulator.command(vm, :fresh, [options])
    Node.disconnect(vm.node)
    await(vm, "fresh device", & &1, 180_000)
    for key <- ~w(vm lan1_device disk), do: fault(vm, key, nil)
    fault(vm, "receive", if(options[:receive_stall], do: "LAN1 receive stalled"))
    report_network(vm)
    vm
  end

  def cable_cycle(vm) do
    try do
      network(vm, %{cables: %{lan1: false}})

      Scenarios.Device.await(vm, "cable disconnected", fn status ->
        Enum.any?(status.connections.ports, &match?(%{name: "eth0", link: false}, &1))
      end)
    after
      network(vm, %{cables: %{lan1: true}})
    end

    Scenarios.Device.await(vm, "link and address recovered", &Scenarios.Device.addressed?/1)
  end

  def check_firewall(vm) do
    for tool <- ~w(iptables ip6tables), table <- ~w(filter nat mangle) do
      {output, status} =
        :erpc.call(
          vm.node,
          System,
          :cmd,
          ["/usr/sbin/#{tool}", ["--wait", "5", "-t", table, "-S"], [stderr_to_stdout: true]],
          10_000
        )

      assert status == 0, "Guest #{tool} #{table} table unavailable: #{output}"
      if table == "nat", do: assert(output =~ "-P POSTROUTING ")
    end

    :ok
  end

  def internet_request(vm, timeout \\ 15_000) do
    result =
      :erpc.call(
        vm.node,
        :httpc,
        :request,
        [
          :get,
          {~c"https://example.com/", [{~c"connection", ~c"close"}]},
          [timeout: timeout, connect_timeout: timeout, autoredirect: false],
          [body_format: :binary]
        ],
        timeout + 5000
      )

    case result do
      {:ok, {{_, status, _}, _, _}} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  # Never return the private login URL through assertions or diagnostics.
  def login_ready?(vm),
    do:
      match?({:ok, "https://" <> _}, :erpc.call(vm.node, NervesGate.Remote, :login_url, [], 2000))

  def cleanup do
    callbacks =
      (Process.delete(:qemu_cleanup) || [])
      |> Enum.sort_by(fn {{_, kind}, _} -> if kind == :pause, do: 0, else: 1 end)

    errors =
      for {_, callback} <- callbacks, reduce: [] do
        errors ->
          # Run every callback, but let exits after uncertain control propagate.
          try do
            callback.()
            errors
          rescue
            # reach:disable-next-line bare_rescue -- any raised cleanup failure blocks the device
            error -> [error | errors]
          end
      end

    Process.delete(:qemu_cleanup)
    if errors != [], do: raise("Fault cleanup failed; Reset the simulator devices")
  end

  def on_exit(id, callback) do
    callbacks = Process.get(:qemu_cleanup, [])
    Process.put(:qemu_cleanup, [{id, callback} | List.keydelete(callbacks, id, 0)])
  end

  defp report_network(vm) do
    config = network(vm)

    for {port, up} <- config.cables do
      fault(
        vm,
        to_string(port),
        if(!up, do: "#{String.upcase(to_string(port))} cable disconnected")
      )
    end

    fault(
      vm,
      "latency",
      if(config.uplink.delay_ms > 0, do: "Uplink delay +#{config.uplink.delay_ms} ms")
    )

    fault(
      vm,
      "internet",
      %{none: nil, alternate: "Uplink packet loss 50%", all: "Internet outage"}[
        config.uplink.loss
      ]
    )

    if report = Process.get(:qemu_topology), do: report.(vm.id, topology(vm))
  end

  defp fault(vm, key, label) do
    if report = Process.get(:qemu_fault), do: report.(vm.id, key, label)
    :ok
  end
end

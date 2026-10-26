defmodule Scenarios.Cases.PowerSaved do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "saved configuration and external connections survive abrupt QEMU process loss",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    saved = settings("eth0")
    save(vm, saved)

    Qemu.network(vm, %{
      internet: :lan2,
      cables: %{lan1: false},
      uplink: %{delay_ms: 200, loss: :alternate}
    })

    network = Qemu.network(vm)
    restarted = Qemu.power_cycle(vm)

    assert Scenarios.Qemu.topology(vm) == %{lan1: :application, lan2: :internet}
    assert Qemu.network(restarted) == network

    Scenarios.Device.await(
      restarted,
      "external cable fault survives VM process crash",
      fn status ->
        Enum.any?(status.connections.ports, &match?(%{name: "eth0", link: false}, &1))
      end
    )

    Qemu.network(restarted, Simulator.Network.defaults())

    restored =
      Scenarios.Device.await(restarted, "saved settings after VM process crash", fn status ->
        status.network.setup_completed && status.network.desired == saved &&
          not status.network.recovering && addressed?(status)
      end)

    assert restored.network.pending == nil
  end
end

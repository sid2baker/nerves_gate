defmodule NervesGateQEMU.FaultIntegrationTest do
  use ExUnit.Case

  alias NervesGateQEMU.Fault
  alias NervesGateQEMU.Status

  @moduletag :integration
  @moduletag timeout: 120_000

  setup do
    on_exit(fn -> Fault.heal_all() end)
    :ok
  end

  test "a deterministic uplink disconnect is observable and heals through local HTTP" do
    initial = Status.all().devices

    assert Enum.count_until(initial, 3) == 3,
           "start at least three QEMU gateways before running fault integration tests"

    assert Enum.all?(initial, &ready?/1),
           "commission every QEMU gateway and wait for Internet, Tailnet, and cluster convergence"

    victim = hd(initial)
    assert :ok = Fault.link_down(victim.id)

    assert_eventually(
      fn ->
        observed = device_status(victim.id)
        observed.fault == :link_down and observed.link == :down and observed.internet == :offline
      end,
      "#{victim.id} did not report its disconnected uplink"
    )

    assert :ok = Fault.heal(victim.id)

    assert_eventually(
      fn -> device_status(victim.id) |> ready?() end,
      "#{victim.id} did not recover Internet, Tailnet, and cluster connectivity"
    )
  end

  defp device_status(id) do
    Enum.find(Status.all().devices, &(&1.id == id)) || flunk("QEMU device disappeared: #{id}")
  end

  defp ready?(device) do
    device.vm == :running and device.link == :up and device.configured and
      device.internet == :online and device.tailnet == :online and device.cluster == :online
  end

  defp assert_eventually(predicate, message, attempts \\ 60)

  defp assert_eventually(predicate, message, attempts) when attempts > 0 do
    if predicate.() do
      :ok
    else
      Process.sleep(1_000)
      assert_eventually(predicate, message, attempts - 1)
    end
  end

  defp assert_eventually(_predicate, message, 0), do: flunk(message)
end

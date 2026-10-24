defmodule Scenarios.Cases.Loss do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "severe upstream packet loss preserves management and HTTPS recovers",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    Qemu.network(vm, %{uplink: %{loss: :none}})
    Scenarios.Device.await(vm, "public Internet reachable", &internet?/1, 60_000)

    try do
      Qemu.network(vm, %{uplink: %{loss: :alternate}})
      before = Scenarios.Qemu.network_stats(vm)
      # Losing half the uplink packets may legitimately prevent a TLS handshake.
      # Exercise real traffic, then require management and recovery, not success
      # within an arbitrary retransmission budget while the fault is active.
      Qemu.internet_request(vm, 10_000)
      status = Scenarios.Device.status(vm)
      assert status.device.available
      assert addressed?(status)
      stats = Scenarios.Qemu.network_stats(vm)
      dropped = stats.dropped - before.dropped
      attempted = stats.candidates - before.candidates
      assert dropped > 0
      assert abs(2 * dropped - attempted) <= 1
      assert stats.overflow == before.overflow
    after
      Qemu.network(vm, %{uplink: %{loss: :none}})
    end

    assert {:ok, 200} = Qemu.internet_request(vm)
    Scenarios.Device.await(vm, "healthy upstream after packet loss removed", &internet?/1, 60_000)
  end
end

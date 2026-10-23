defmodule Simulator.Scenarios.Loss do
  @moduledoc false
  import ExUnit.Assertions
  import Simulator.ScenarioHelpers
  alias Simulator.TestQemu, as: Qemu

  def spec, do: %{:name => "severe upstream packet loss preserves management and HTTPS recovers"}

  def run(%{device: vm}) do
    Qemu.network(vm, %{uplink: %{loss: :none}})
    Qemu.await(vm, "public Internet reachable", &internet?/1, 60_000)

    try do
      Qemu.network(vm, %{uplink: %{loss: :alternate}})
      before = Simulator.TestQemu.network_stats(vm)
      # Losing half the uplink packets may legitimately prevent a TLS handshake.
      # Exercise real traffic, then require management and recovery, not success
      # within an arbitrary retransmission budget while the fault is active.
      Qemu.internet_request(vm, 10_000)
      status = Qemu.status(vm)
      assert status.backend.available
      assert addressed?(status)
      stats = Simulator.TestQemu.network_stats(vm)
      dropped = stats.dropped - before.dropped
      attempted = stats.candidates - before.candidates
      assert dropped > 0
      assert abs(2 * dropped - attempted) <= 1
      assert stats.overflow == before.overflow
    after
      Qemu.network(vm, %{uplink: %{loss: :none}})
    end

    assert {:ok, 200} = Qemu.internet_request(vm)
    Qemu.await(vm, "healthy upstream after packet loss removed", &internet?/1, 60_000)
  end
end

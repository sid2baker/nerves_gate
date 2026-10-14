defmodule NervesGate.Scenarios.Loss do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "severe upstream packet loss preserves management and HTTPS recovers"

  def run(vm) do
    Qemu.start_internet_faults(vm)
    Qemu.await(vm, "public Internet reachable", &internet?/1, 60_000)

    try do
      Qemu.lose_internet_packets(vm)
      # Losing half the uplink packets may legitimately prevent a TLS handshake.
      # Exercise real traffic, then require management and recovery, not success
      # within an arbitrary retransmission budget while the fault is active.
      Qemu.internet_request(vm, 10_000)
      status = Qemu.status(vm)
      assert status.backend.available
      assert addressed?(status)
      assert Qemu.dropped_packets(vm) > 0
    after
      Qemu.restore_internet(vm)
    end

    assert {:ok, 200} = Qemu.internet_request(vm)
    Qemu.await(vm, "healthy upstream after packet loss removed", &internet?/1, 60_000)
  end
end

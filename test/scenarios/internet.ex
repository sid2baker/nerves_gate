defmodule NervesGate.Scenarios.Internet do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "upstream outage is detected with Ethernet still connected and recovers"

  def run(vm) do
    Qemu.start_upstream(vm)
    save(vm, settings("eth0"))
    Qemu.await(vm, "Internet probe targets reachable", &internet?/1, 60_000)

    try do
      Qemu.drop_internet(vm)

      degraded =
        Qemu.await(
          vm,
          "upstream unavailable with cable connected",
          fn status ->
            assert addressed?(status),
                   "Upstream failure must not remove the Ethernet link/address"

            Enum.any?(status.connections.ports, &match?(%{name: "eth0", connection: :lan}, &1))
          end,
          90_000
        )

      assert Qemu.dropped_packets(vm) > 0
      assert degraded.backend.available
      assert degraded.connections.internet.health == "unverified"
    after
      Qemu.restore_internet(vm)
    end

    Qemu.await(vm, "upstream recovered", &internet?/1, 60_000)
  end
end

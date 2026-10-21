defmodule NervesGateSim.Scenarios.Internet do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGateSim.ScenarioHelpers
  alias NervesGateSim.TestQemu, as: Qemu

  def spec, do: %{:name => "real DNS/HTTPS works, fails during an upstream outage, and recovers"}

  def run(%{device: vm}) do
    Qemu.network(vm, %{uplink: %{loss: :none}})
    save(vm, settings("eth0"))
    assert {:ok, 200} = Qemu.internet_request(vm)
    Qemu.await(vm, "public Internet reachable", &internet?/1, 60_000)

    try do
      Qemu.network(vm, %{uplink: %{loss: :all}})
      before = NervesGateSim.TestQemu.network_stats(vm).dropped
      assert {:error, _} = Qemu.internet_request(vm, 5_000)

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

      assert NervesGateSim.TestQemu.network_stats(vm).dropped > before
      assert degraded.backend.available
      assert degraded.connections.internet.health == "unverified"
    after
      Qemu.network(vm, %{uplink: %{loss: :none}})
    end

    assert {:ok, 200} = Qemu.internet_request(vm)
    Qemu.await(vm, "upstream recovered", &internet?/1, 60_000)
  end
end

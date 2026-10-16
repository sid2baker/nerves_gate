defmodule NervesGate.Scenarios.DevDiscovery do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.DevDiscovery
  alias NervesGate.TestQemu, as: Qemu

  def spec, do: %{name: "Discovery authenticates distinct real gateways and rejects ambiguity"}

  def run(%{device: vm, devices: devices}) do
    guest = vm.node
    {:ok, address} = :inet.parse_address(String.to_charlist(vm.address))
    assert Qemu.status(vm).system.node == guest
    assert {:ok, ^address} = DevDiscovery.node_address(Atom.to_string(guest))
    assert :error = DevDiscovery.node_address("other@192.168.77.2")
    assert :error = DevDiscovery.node_address("nerves_gate@999.168.77.2")
    assert :error = DevDiscovery.node_address("nerves_gate@ec100.example.ts.net")

    assert :init.get_argument(:epmd_port) == {:ok, [[Integer.to_charlist(vm.forwards.epmd)]]}
    assert {:port, 9100, _} = :erl_epmd.port_please(~c"nerves_gate", address, 2000)
    assert :noport = :erl_epmd.port_please(~c"gateway_ui", address, 2000)
    assert [gateway] = DevDiscovery.discover([address, address])
    assert gateway == %{node: guest, target: :x86_64}
    assert {:ok, ^guest} = DevDiscovery.select([gateway], :x86_64)
    assert {:error, :not_found} = DevDiscovery.select([gateway], :ec100)
    assert {:error, :not_found} = DevDiscovery.select([], :ec100)
    assert {:ok, ^guest} = DevDiscovery.select([gateway, gateway], :x86_64)

    addresses =
      Enum.map(devices, fn {_, device} ->
        {:ok, address} = :inet.parse_address(String.to_charlist(device.address))
        address
      end)

    found = DevDiscovery.discover(addresses)
    assert length(found) == map_size(devices)

    if match?([_, _ | _], found) do
      assert {:error, {:multiple, nodes}} = DevDiscovery.select(found, :x86_64)
      assert nodes == Enum.sort(Enum.map(found, & &1.node))
    end

    assert guest in Node.list(:connected)
  end
end

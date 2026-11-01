defmodule NervesGate.HardwareInventoryTest do
  use ExUnit.Case, async: true
  alias NervesGate.Hardware.Ports

  test "every board resource is normalized, including absent ports and expansion GPIOs" do
    for target <- [:ec100, :em300, :x86_64] do
      config = Config.Reader.read!("config/config.exs", env: :dev, target: target)
      declared = config[:nerves_gate][:board][:ports]
      inventory = Ports.snapshot(declared, [])
      assert Enum.map(inventory, & &1.id) == Enum.map(declared, & &1.id)

      for {port, source} <- Enum.zip(inventory, declared) do
        assert Map.take(port, [:id, :kind, :label, :assignable]) ==
                 Map.take(source, [:id, :kind, :label, :assignable])

        assert is_boolean(port.present)
        assert port.gpios == Map.get(source, :gpios, %{})
        if port.kind in [:rs485, :iotrouter_expansion], do: assert(port.path == "/dev/#{port.id}")
      end
    end
  end

  test "Ethernet count and identity come only from board declarations, not detected interfaces" do
    declared = [%{id: "eth2", kind: :ethernet, label: "Equipment", assignable: true}]
    network = [%{name: "eth2", present: true, link: true}, %{name: "eth9", present: true}]

    assert [%{id: "eth2", kind: :ethernet, interface: "eth2", present: true, link: true}] =
             Ports.snapshot(declared, network)

    assert [%{id: "eth2", present: false}] = Ports.snapshot(declared, [])
    assert [] = Ports.snapshot([], network)
  end
end

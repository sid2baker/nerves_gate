defmodule NervesGate.NetworkDefaultsTest do
  use ExUnit.Case, async: false
  alias NervesGate.Config

  setup do
    previous = Application.fetch_env(:nerves_gate, :board)

    on_exit(fn ->
      case previous do
        {:ok, board} -> Application.put_env(:nerves_gate, :board, board)
        :error -> Application.delete_env(:nerves_gate, :board)
      end
    end)
  end

  test "without a dedicated WAN every port runs DHCP and the Internet port is found automatically" do
    board =
      Elixir.Config.Reader.read!("config/config.exs", env: :dev, target: :ec100)[:nerves_gate][
        :board
      ]

    Application.put_env(:nerves_gate, :board, board)

    assert Config.defaults() == %{
             "setup_completed" => false,
             "network" => %{"mode" => "unconfigured"}
           }

    configs =
      Config.defaults()["network"] |> NervesGate.Network.Vintage.configurations() |> Map.new()

    assert configs["eth0"].ipv4 == %{method: :dhcp}
    assert configs["eth1"].ipv4 == %{method: :dhcp}
  end

  test "Ethernet policy works with zero, one or three nonstandard resources" do
    for ids <- [[], ["wan9"], ["wan9", "lan7", "lan8"]] do
      ports = for id <- ids, do: %{id: id, kind: :ethernet, label: id, assignable: true}
      Application.put_env(:nerves_gate, :board, %{ports: ports})
      assert NervesGate.Board.ethernet() == ids
      settings = Map.put(Map.new(ids, &{&1, nil}), "mode", "ports")
      assert {:ok, ^settings} = Config.validate_network(settings)
      assert {:error, _} = Config.validate_network(Map.put(settings, "unknown0", nil))

      configs =
        Config.defaults()["network"] |> NervesGate.Network.Vintage.configurations() |> Map.new()

      assert Enum.sort(Map.keys(configs)) == Enum.sort(ids)
      for id <- ids, do: assert(configs[id].ipv4 == %{method: :dhcp})
    end
  end

  test "a board's dedicated WAN is the factory Internet port with DHCP" do
    board =
      Elixir.Config.Reader.read!("config/config.exs", env: :dev, target: :em300)[:nerves_gate][
        :board
      ]

    Application.put_env(:nerves_gate, :board, board)
    network = Config.defaults()["network"]

    assert network == %{
             "mode" => "ports",
             "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
             "eth1" => nil
           }

    assert {:ok, ^network} = Config.validate_network(network)
    configs = network |> NervesGate.Network.Vintage.configurations() |> Map.new()
    assert configs["eth0"].ipv4 == %{method: :dhcp}
    assert configs["eth1"].ipv4 == %{method: :disabled}
    refute Map.has_key?(configs, "br0")
  end
end

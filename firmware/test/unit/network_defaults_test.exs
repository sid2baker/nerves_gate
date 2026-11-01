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
    Application.put_env(:nerves_gate, :board, %{})

    assert Config.defaults() == %{
             "setup_completed" => false,
             "network" => %{"mode" => "unconfigured"}
           }

    configs =
      Config.defaults()["network"] |> NervesGate.Network.Vintage.configurations() |> Map.new()

    assert configs["eth0"].ipv4 == %{method: :dhcp}
    assert configs["eth1"].ipv4 == %{method: :dhcp}
  end

  test "a board's dedicated WAN is the factory Internet port with DHCP" do
    Application.put_env(:nerves_gate, :board, %{internet_port: "eth0"})
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
    assert {:ok, ^network} = NervesGate.Network.Vintage.from_configurations(%{})
  end
end

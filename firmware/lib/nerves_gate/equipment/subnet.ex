defmodule NervesGate.Equipment.Subnet do
  @moduledoc "Confirmed equipment scope. Never derives a scan or route from submitted interface names."
  import Bitwise
  alias NervesGate.Config

  def from_status(%{config: %{"network" => network}, trial: nil, recovering: false}) do
    case network do
      %{"mode" => "ports"} ->
        build(Config.role_port(network, "equipment"), Config.role_address(network, "equipment"))

      %{"mode" => "shared", "equipment" => address} ->
        build("br0", address)

      _ ->
        {:error, :equipment_unconfigured}
    end
  end

  def from_status(_) do
    {:error, :network_unavailable}
  end

  @doc "Active work requires the confirmed address, physical link and expected topology."
  def active(status) do
    with {:ok, scope} <- from_status(status),
         true <- ready?(scope, status) do
      {:ok, scope}
    else
      false -> {:error, :equipment_not_ready}
      error -> error
    end
  end

  defp ready?(scope, %{observed: %{ports: ports, bridge: bridge} = observed, config: config}) do
    interface =
      if scope.interface == "br0" do
        bridge
      else
        Enum.find(ports, &(&1.name == scope.interface))
      end

    addressed?(interface, scope) and topology?(scope.interface, ports, interface) and
      NervesGate.Network.Policy.conflicts(observed, config["network"]) == []
  end

  defp ready?(_, _) do
    false
  end

  defp addressed?(%{present: true, link: true, state: :configured, addresses: addresses}, scope) do
    Enum.any?(addresses, &(&1.address == scope.address and &1.prefix_length == scope.prefix))
  end

  defp addressed?(_, _) do
    false
  end

  defp topology?("br0", ports, _) do
    Enum.all?(ports, &(not &1.present or &1.master == "br0"))
  end

  defp topology?(_, _, %{master: nil}) do
    true
  end

  defp topology?(_, _, _) do
    false
  end

  def build(interface, %{"ip_method" => "static", "static_ip" => address, "subnet_mask" => mask})
      when interface in ["eth0", "eth1", "br0"] do
    with {:ok, ip} <- Config.ipv4(address), {:ok, prefix} <- Config.prefix_length(mask) do
      network = (integer(ip) >>> (32 - prefix)) <<< (32 - prefix)

      {:ok,
       %{
         interface: interface,
         address: address,
         prefix: prefix,
         network: network,
         cidr: "#{string(network)}/#{prefix}"
       }}
    end
  end

  def build(_, _), do: {:error, :equipment_unconfigured}

  def contains?(scope, address) do
    case Config.ipv4(address) do
      {:ok, ip} -> integer(ip) >>> (32 - scope.prefix) == scope.network >>> (32 - scope.prefix)
      _ -> false
    end
  end

  def host?(scope, address) do
    case Config.ipv4(address) do
      {:ok, ip} ->
        value = integer(ip)

        contains?(scope, address) and address != scope.address and
          value not in [scope.network, scope.network + (1 <<< (32 - scope.prefix)) - 1]

      _ ->
        false
    end
  end

  # On a large equipment subnet, probe only the /24 containing the gateway.
  # At most 254 destinations, never a subnet-wide sweep of a /8 or /16.
  def scan(scope) do
    {:ok, address} = Config.ipv4(scope.address)
    prefix = max(scope.prefix, 24)
    first = (integer(address) >>> (32 - prefix)) <<< (32 - prefix)
    last = first + (1 <<< (32 - prefix)) - 1

    %{
      cidr: "#{string(first)}/#{prefix}",
      addresses: for(n <- (first + 1)..(last - 1), string(n) != scope.address, do: string(n))
    }
  end

  def key(scope), do: "#{scope.interface}:#{scope.cidr}:#{scope.address}"
  def integer({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  def string(value), do: value |> tuple() |> :inet.ntoa() |> to_string()

  def tuple(value),
    do: {value >>> 24 &&& 255, value >>> 16 &&& 255, value >>> 8 &&& 255, value &&& 255}
end

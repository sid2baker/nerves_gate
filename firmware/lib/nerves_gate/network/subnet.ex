defmodule NervesGate.Network.Subnet do
  @moduledoc "Pure IPv4 scopes for application-owned network leases."
  import Bitwise
  alias NervesGate.Config

  def from_status(%{
        local: %{interface: name, phase: phase},
        observed: %{ports: ports},
        trial: nil,
        recovering: false
      })
      when phase in [:configured, :advertised] do
    with %{master: nil, addresses: [%{address: address, prefix_length: prefix}]} <-
           Enum.find(ports, &(&1.name == name)),
         do: build(name, address, prefix)
  end

  def from_status(_),
    do: {:error, %{code: "local_unconfigured", message: "No configured application lease."}}

  def build(interface, %{"ip_method" => "static", "static_ip" => address, "subnet_mask" => mask}) do
    with {:ok, prefix} <- Config.prefix_length(mask), do: build(interface, address, prefix)
  end

  def build(_, _), do: {:error, :invalid_subnet}

  def build(interface, address, prefix) when interface in ["eth0", "eth1"] and prefix in 1..30 do
    with {:ok, ip} <- Config.ipv4(address) do
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

  def build(_, _, _), do: {:error, :invalid_subnet}

  defp integer({a, b, c, d}), do: a <<< 24 ||| b <<< 16 ||| c <<< 8 ||| d
  defp string(value), do: value |> tuple() |> :inet.ntoa() |> to_string()

  defp tuple(value),
    do: {value >>> 24 &&& 255, value >>> 16 &&& 255, value >>> 8 &&& 255, value &&& 255}
end

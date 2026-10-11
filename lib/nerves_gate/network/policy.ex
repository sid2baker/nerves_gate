defmodule NervesGate.Network.Policy do
  @moduledoc "Pure trial admission, topology readiness and observed subnet conflict checks."
  alias NervesGate.Config

  def available(nil), do: {:error, :unavailable}
  def available(%{config: nil}), do: {:error, :invalid_saved_config}
  def available(%{recovering: true}), do: {:error, :recovery_in_progress}
  def available(%{trial: trial}) when not is_nil(trial), do: {:error, :trial_in_progress}
  def available(_), do: :ok

  def matching(%{trial: %{id: id}}, id), do: :ok
  def matching(_, _), do: {:error, :no_matching_trial}

  @doc "Readiness is configured topology, NOT Internet access, a link or a DHCP lease."
  def ready?(
        %{bridge: bridge, ports: ports} = observed,
        %{"mode" => "shared", "equipment" => network} = settings
      ) do
    bridge.present and bridge.state == :configured and bridge.method == network["ip_method"] and
      Enum.all?(ports, &(not &1.present or &1.master == "br0")) and
      (network["ip_method"] == "dhcp" or address_matches?(bridge.addresses, network)) and
      conflicts(observed, settings) == []
  end

  def ready?(%{ports: ports} = observed, %{"mode" => "ports"} = network) do
    Enum.all?(Config.ports(network), fn {name, setting} ->
      port_ready?(Enum.find(ports, &(&1.name == name)), setting)
    end) and conflicts(observed, network) == []
  end

  def ready?(_, _), do: false

  def conflicts(%{ports: ports, bridge: bridge} = observed, network) do
    networks = if network["mode"] == "shared", do: [bridge], else: ports
    usb = Map.get(observed, :usb, %{addresses: []})

    pairs =
      for {left, i} <- Enum.with_index(networks ++ [usb]),
          {right, j} <- Enum.with_index(networks ++ [usb]),
          i < j,
          a <- Map.get(left, :addresses, []),
          b <- Map.get(right, :addresses, []),
          Config.overlap?(a.address, a.prefix_length, b.address, b.prefix_length),
          do: {i, j}

    if pairs == [],
      do: [],
      else: [
        "Network addresses overlap. Use different Internet, equipment and USB subnets before continuing."
      ]
  end

  def conflicts(_, _), do: []

  defp port_ready?(nil, setting), do: is_nil(setting)
  defp port_ready?(%{present: false}, setting), do: is_nil(setting)
  defp port_ready?(port, nil), do: configured_port?(port) and port.method == "disabled"

  defp port_ready?(port, %{"address" => address}) do
    configured_port?(port) and port.method == address["ip_method"] and
      (port.method == "dhcp" or address_matches?(port.addresses, address))
  end

  defp configured_port?(port), do: port.state == :configured and is_nil(port.master)

  defp address_matches?(addresses, network) do
    Enum.any?(addresses, fn %{address: address, prefix_length: prefix} ->
      case network["ip_method"] do
        "dhcp" ->
          match?({:ok, {a, _, _, _}} when a > 0 and a < 224 and a != 127, Config.ipv4(address))

        "static" ->
          address == network["static_ip"] and
            Config.prefix_length(network["subnet_mask"]) == {:ok, prefix}
      end
    end)
  end
end

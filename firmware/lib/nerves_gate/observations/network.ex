defmodule NervesGate.Observations.Network do
  @moduledoc "Pure interpretation of permitted uplinks and observed Internet connectivity."
  alias NervesGate.Config

  def settings(nil), do: nil
  def settings(%{trial: %{network: network}}), do: network
  def settings(%{config: config}), do: config && config["network"]

  def internet(status) do
    network = settings(status)
    observed = status && status.observed
    ethernet = ethernet_interfaces(network, observed)
    cellular = observed && Map.get(observed, :cellular)
    mode = Config.internet(network)["mode"]
    permitted = uplinks(network, ethernet, cellular)
    online = Enum.filter(permitted, &online?/1)

    selected = selected_interface(network, online)

    connections = Enum.map(permitted, &connection/1)

    %{
      expected: expected?(network),
      online: online != [],
      connection: aggregate(connections),
      mode: mode,
      selected: selected && selected.name,
      ethernet: aggregate(Enum.map(ethernet, &connection/1)),
      cellular: if(Config.cellular?(network), do: connection(cellular), else: :disabled),
      backup: mode == "backup" and selected != nil and selected == cellular
    }
  end

  # Discovery can observe multiple working uplinks without choosing a role or
  # claiming which route the kernel uses. Ambiguity is not an Internet outage.
  defp selected_interface(%{"mode" => "unconfigured"}, [_, _ | _]), do: nil
  defp selected_interface(_, online), do: List.first(online)

  def internet_interface(network, observed) do
    candidates =
      uplinks(
        network,
        ethernet_interfaces(network, observed),
        observed && Map.get(observed, :cellular)
      )

    Enum.find(candidates, &online?/1) ||
      Enum.find(candidates, &match?(%{present: true, link: true, addresses: [_ | _]}, &1)) ||
      Enum.find(candidates, &match?(%{present: true, link: true}, &1)) ||
      Enum.find(candidates, &(&1 != nil))
  end

  defp uplinks(network, ethernet, cellular) do
    case Config.internet(network)["mode"] do
      "cellular" -> [cellular]
      "backup" -> ethernet ++ [cellular]
      _ -> ethernet
    end
  end

  defp ethernet_interfaces(_, nil), do: [nil]
  defp ethernet_interfaces(%{"mode" => "unconfigured"}, observed), do: observed.ports
  defp ethernet_interfaces(%{"mode" => "shared"}, observed), do: [observed.bridge]

  defp ethernet_interfaces(network, observed) do
    name = Config.role_port(network, "internet")
    [Enum.find(observed.ports, &(&1.name == name))]
  end

  defp expected?(nil), do: false
  defp expected?(%{"mode" => "unconfigured"}), do: false
  defp expected?(%{"mode" => "shared"}), do: true

  defp expected?(network),
    do: Config.cellular?(network) or Config.role_port(network, "internet") != nil

  defp aggregate(connections) do
    cond do
      :internet in connections -> :internet
      :unknown in connections -> :unknown
      :lan in connections -> :lan
      true -> :disconnected
    end
  end

  defp connection(nil), do: :unknown
  defp connection(%{present: false}), do: :disconnected
  defp connection(interface), do: Map.get(interface, :connection) || :unknown

  defp online?(nil), do: false

  defp online?(interface),
    do:
      interface.present and interface.link and connection(interface) == :internet and
        Map.get(interface, :addresses, []) != []
end

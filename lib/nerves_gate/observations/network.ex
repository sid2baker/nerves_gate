defmodule NervesGate.Observations.Network do
  @moduledoc "Pure interpretation of permitted uplinks and observed Internet connectivity."
  alias NervesGate.Config
  alias NervesGate.Network.Discovery

  def settings(nil), do: nil
  def settings(%{trial: %{network: network}}), do: network
  def settings(%{config: config}), do: config && config["network"]

  def internet(status) do
    network = settings(status)
    observed = status && status.observed
    ethernet = ethernet_interface(network, observed)
    cellular = observed && Map.get(observed, :cellular)
    mode = Config.internet(network)["mode"]
    permitted = uplinks(network, ethernet, cellular)
    selected = Enum.find(permitted, &online?/1)
    connections = Enum.map(permitted, &connection/1)

    %{
      expected: expected?(network),
      online: selected != nil,
      connection: aggregate(connections),
      mode: mode,
      selected: selected && selected.name,
      ethernet: connection(ethernet),
      cellular: if(Config.cellular?(network), do: connection(cellular), else: :disabled),
      backup: mode == "backup" and selected != nil and selected == cellular
    }
  end

  def internet_interface(network, observed) do
    candidates =
      uplinks(
        network,
        ethernet_interface(network, observed),
        observed && Map.get(observed, :cellular)
      )

    Enum.find(candidates, &online?/1) || Enum.find(candidates, &(&1 != nil))
  end

  defp uplinks(network, ethernet, cellular) do
    case Config.internet(network)["mode"] do
      "cellular" -> [cellular]
      "backup" -> [ethernet, cellular]
      _ -> [ethernet]
    end
  end

  defp ethernet_interface(_, nil), do: nil
  defp ethernet_interface(%{"mode" => "shared"}, observed), do: observed.bridge

  defp ethernet_interface(network, observed) do
    name =
      if network && network["mode"] == "unconfigured",
        do: Discovery.internet_port(observed.ports),
        else: Config.role_port(network, "internet")

    Enum.find(observed.ports, &(&1.name == name))
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
      interface.present and connection(interface) == :internet and
        Map.get(interface, :addresses, []) != []
end

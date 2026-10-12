defmodule NervesGate.Observations.Network do
  @moduledoc "Pure interpretation of requested roles and observed Internet connectivity."
  alias NervesGate.Config
  alias NervesGate.Network.Discovery

  def settings(nil), do: nil
  def settings(%{trial: %{network: network}}), do: network
  def settings(%{config: config}), do: config && config["network"]

  def internet(status) do
    network = settings(status)
    observed = status && status.observed
    interface = internet_interface(network, observed)

    %{
      expected: expected?(network),
      online: online?(interface),
      connection: connection(interface)
    }
  end

  def internet_interface(_, nil), do: nil
  def internet_interface(%{"mode" => "shared"}, observed), do: observed.bridge

  def internet_interface(network, observed) do
    name =
      if network && network["mode"] == "unconfigured",
        do: Discovery.internet_port(observed.ports),
        else: Config.role_port(network, "internet")

    Enum.find(observed.ports, &(&1.name == name))
  end

  defp expected?(nil), do: false
  defp expected?(%{"mode" => "unconfigured"}), do: false
  defp expected?(%{"mode" => "shared"}), do: true
  defp expected?(network), do: Config.role_port(network, "internet") != nil

  defp connection(nil), do: :unknown
  defp connection(%{present: false}), do: :disconnected
  defp connection(interface), do: Map.get(interface, :connection) || :unknown

  defp online?(nil), do: false

  defp online?(interface),
    do:
      interface.present and interface.link and Map.get(interface, :addresses, []) != [] and
        Map.get(interface, :connection) == :internet
end

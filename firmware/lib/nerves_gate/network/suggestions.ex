defmodule NervesGate.Network.Suggestions do
  @moduledoc "Suggestions from observed ports. Never changes or persists port roles."

  def internet_port(ports) do
    online = Enum.filter(ports, &(Map.get(&1, :connection) == :internet and usable?(&1)))
    addressed = Enum.filter(ports, &usable?/1)

    case {online, addressed} do
      {[port], _} -> port.name
      {[], [port]} -> port.name
      _ -> nil
    end
  end

  def status(port) do
    cond do
      not port.present -> "Not installed"
      not port.link -> "No cable connected"
      Map.get(port, :connection) == :internet and usable?(port) -> "Internet connected"
      Map.get(port, :addresses, []) != [] -> "Local network connected · Internet not verified"
      true -> "Cable connected · No address yet"
    end
  end

  defp usable?(port), do: port.present and port.link and Map.get(port, :addresses, []) != []
end

defmodule NervesGate.Hardware.Ports do
  @moduledoc """
  Normalizes the board's declared resources with runtime presence. Physical
  inventory only: never opens UARTs, captures traffic or guesses wiring.
  """
  alias NervesGate.Linux.CAN

  @doc "One entry per declared resource, in board order; `network` is Network's port observation."
  def snapshot(declared, network) do
    Enum.map(declared, fn %{id: id, kind: kind, label: label} = port ->
      Map.merge(observe(kind, id, network), %{
        id: id,
        kind: kind,
        label: label,
        assignable: Map.fetch!(port, :assignable),
        gpios: Map.get(port, :gpios, %{})
      })
    end)
  end

  defp observe(:ethernet, id, network) do
    case Enum.find(network, &(&1.name == id)) do
      nil -> %{present: false, interface: id}
      port -> port |> Map.delete(:name) |> Map.put(:interface, id)
    end
  end

  defp observe(:can, id, _),
    do: CAN.snapshot(id) |> Map.drop([:name, :kind]) |> Map.put(:interface, id)

  # Serial-like resources: RS485 ports and the IOTRouter expansion bus.
  defp observe(_, id, _) do
    path = "/dev/" <> id
    %{present: match?({:ok, %{type: :device}}, File.stat(path)), path: path}
  end
end

defmodule NervesGate.Buses.EC100 do
  @moduledoc "Only can0/can1 and ttyS3/ttyS4. Never opens the boot console or guesses DE/RTS GPIOs."
  alias NervesGate.Buses.{Policy, Serial}
  alias NervesGate.Linux.CAN

  def snapshot(_) do
    Enum.map(Policy.ports(), fn
      name when name in ["can0", "can1"] ->
        status = CAN.snapshot(name)
        Map.merge(status, %{transport: "can", enabled: status.up})

      name ->
        %{
          name: name,
          transport: "rs485",
          present: present?(name),
          enabled: false,
          profile: "9600 8N1 · automatic direction"
        }
    end)
  end

  def execute(:configure, name, params, _) when name in ["can0", "can1"],
    do: CAN.configure(name, params)

  def execute(:capture, name, _, _) when name in ["can0", "can1"] do
    # Recheck immediately before opening a receive socket; refuse normal/unknown mode.
    case CAN.snapshot(name) do
      %{present: true, up: true, listen_only: true} ->
        with {:ok, frames} <- CAN.capture(name), do: {:ok, %{frames: frames}}

      _ ->
        {:error, :can_not_passive}
    end
  end

  def execute(operation, name, params, _)
      when name in ["ttyS3", "ttyS4"] and operation in [:capture, :modbus_read],
      do: Serial.run("/dev/" <> name, operation, params)

  defp present?(name) do
    match?({:ok, %{type: :device}}, File.stat("/dev/" <> name))
  end
end

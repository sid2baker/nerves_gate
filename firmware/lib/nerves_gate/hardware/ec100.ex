defmodule NervesGate.Hardware.EC100 do
  @moduledoc "Physical inventory only. Never opens UARTs, captures traffic or guesses DE/RTS wiring."
  alias NervesGate.Linux.CAN

  def snapshot(_) do
    Enum.map(["can0", "can1"], fn name ->
      Map.merge(CAN.snapshot(name), %{transport: "can", kind: :can})
    end) ++
      Enum.map(["ttyS3", "ttyS4"], fn name ->
        %{
          name: name,
          kind: :serial,
          transport: "rs485",
          present: match?({:ok, %{type: :device}}, File.stat("/dev/" <> name)),
          path: "/dev/" <> name,
          profile: "RS485 · automatic direction · 9600 8N1"
        }
      end)
  end
end

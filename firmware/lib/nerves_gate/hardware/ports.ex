defmodule NervesGate.Hardware.Ports do
  @moduledoc """
  Board-declared CAN and serial inventory. Physical inventory only: never opens
  UARTs, captures traffic or guesses DE/RTS wiring.
  """
  alias NervesGate.Linux.CAN

  def snapshot(%{can: can, serial: serial}) do
    Enum.map(can, fn name ->
      Map.merge(CAN.snapshot(name), %{transport: "can", kind: :can})
    end) ++
      Enum.map(serial, fn {name, transport, profile} ->
        %{
          name: name,
          kind: :serial,
          transport: transport,
          present: match?({:ok, %{type: :device}}, File.stat("/dev/" <> name)),
          path: "/dev/" <> name,
          profile: profile
        }
      end)
  end
end

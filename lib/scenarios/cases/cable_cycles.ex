defmodule Scenarios.Cases.CableCycles do
  @moduledoc false

  def spec,
    do: %{
      :name => "three consecutive cable failures recover",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    for _ <- 1..3, do: Scenarios.Qemu.cable_cycle(vm)
  end
end

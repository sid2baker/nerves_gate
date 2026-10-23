defmodule Simulator.Scenarios.CableCycles do
  @moduledoc false
  import Simulator.ScenarioHelpers

  def spec, do: %{:name => "three consecutive cable failures recover"}

  def run(%{device: vm}) do
    for _ <- 1..3, do: cable_cycle(vm)
  end
end

defmodule NervesGate.Scenarios.CableCycles do
  @moduledoc false
  import NervesGate.ScenarioHelpers

  def spec, do: %{:name => "three consecutive cable failures recover"}

  def run(%{device: vm}) do
    for _ <- 1..3, do: cable_cycle(vm)
  end
end

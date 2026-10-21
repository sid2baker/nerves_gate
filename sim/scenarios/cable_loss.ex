defmodule NervesGateSim.Scenarios.CableLoss do
  @moduledoc false
  import NervesGateSim.ScenarioHelpers

  def spec, do: %{:name => "Ethernet cable loss and recovery"}

  def run(%{device: vm}) do
    cable_cycle(vm)
  end
end

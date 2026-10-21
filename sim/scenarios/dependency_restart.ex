defmodule NervesGateSim.Scenarios.DependencyRestart do
  @moduledoc false
  alias NervesGateSim.RecoveryChecks

  def spec,
    do: %{
      name:
        "Tailscale, VintageNet and property-table restarts keep gateway processes and the UI live"
    }

  def run(%{device: vm}) do
    for dependency <- RecoveryChecks.dependencies() do
      RecoveryChecks.crash(vm, dependency)
      RecoveryChecks.assert_projection_follows(vm)
    end
  end
end

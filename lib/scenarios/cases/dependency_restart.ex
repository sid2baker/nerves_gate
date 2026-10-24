defmodule Scenarios.Cases.DependencyRestart do
  @moduledoc false
  alias Scenarios.Recovery

  def spec,
    do: %{
      name:
        "Tailscale, VintageNet and property-table restarts keep gateway processes and the UI live",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    for dependency <- Recovery.dependencies() do
      Recovery.crash(vm, dependency)
      Recovery.assert_projection_follows(vm)
    end
  end
end

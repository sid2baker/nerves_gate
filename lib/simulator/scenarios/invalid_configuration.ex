defmodule Simulator.Scenarios.InvalidConfiguration do
  @moduledoc false
  import ExUnit.Assertions
  import Simulator.ScenarioHelpers
  alias Simulator.TestQemu, as: Qemu

  def spec,
    do: %{
      :name => "invalid configuration is rejected without losing management or changing settings"
    }

  def run(%{device: vm}) do
    before = Qemu.status(vm)
    invalid = %{"mode" => "not-a-mode"}
    assert {:error, %{code: "invalid_parameters"}} = Qemu.call(vm, :network_validate, [invalid])
    assert {:error, %{code: "invalid_parameters"}} = Qemu.call(vm, :network_propose, [invalid])
    after_rejection = Qemu.status(vm)
    assert after_rejection.network.desired == before.network.desired
    assert after_rejection.network.pending == nil
    assert addressed?(after_rejection)
  end
end

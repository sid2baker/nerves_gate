defmodule NervesGate.Scenarios.Freeze do
  @moduledoc false
  import ExUnit.Assertions
  import NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  def spec, do: %{:name => "a frozen VM becomes unreachable and resumes without losing state"}

  def run(%{device: vm}) do
    before = Qemu.status(vm)

    try do
      Qemu.pause(vm)
      assert Qemu.status(vm) == nil
    after
      Qemu.resume(vm)
    end

    recovered = Qemu.await(vm, "VM resumed", &addressed?/1)
    assert recovered.network.desired == before.network.desired
    assert recovered.network.pending == before.network.pending
  end
end

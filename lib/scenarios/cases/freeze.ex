defmodule Scenarios.Cases.Freeze do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "a frozen VM becomes unreachable and resumes without losing state",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    before = Scenarios.Device.status(vm)

    try do
      Qemu.pause(vm)
      assert Scenarios.Device.status(vm) == nil
    after
      Qemu.resume(vm)
    end

    recovered = Scenarios.Device.await(vm, "VM resumed", &addressed?/1)
    assert recovered.network.desired == before.network.desired
    assert recovered.network.pending == before.network.pending
  end
end

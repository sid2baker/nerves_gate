defmodule NervesGateSim.Scenarios.InvalidTrialIds do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGateSim.TestQemu, as: Qemu

  def spec, do: %{:name => "Invalid trial IDs cannot change network settings"}

  def run(%{device: vm}) do
    before = Qemu.status(vm)

    for command <- [:network_confirm, :network_cancel] do
      assert {:error, %{code: "invalid_parameters"}} = Qemu.call(vm, command, [nil])
    end

    after_status = Qemu.status(vm)
    assert after_status.network.desired == before.network.desired
    assert after_status.network.pending == nil
  end
end

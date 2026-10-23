defmodule Dev.Scenarios.InvalidTrialIds do
  @moduledoc false
  import ExUnit.Assertions
  alias Dev.TestDevice, as: Device

  def spec do
    %{
      name: "Invalid trial IDs cannot change network settings",
      requires: %{device: [], fixture: []}
    }
  end

  def run(%{device: device}) do
    before = Device.status(device)
    assert before.backend.available

    for command <- [:network_confirm, :network_cancel] do
      assert {:error, %{code: "invalid_parameters"}} = Device.call(device, command, [nil])
    end

    after_status = Device.status(device)
    assert after_status.backend.available
    assert after_status.network.desired == before.network.desired
    assert after_status.network.pending == before.network.pending
  end
end

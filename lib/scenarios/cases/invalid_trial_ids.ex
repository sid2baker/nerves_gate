defmodule Scenarios.Cases.InvalidTrialIds do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.Device, as: Device

  def spec do
    %{
      name: "Invalid trial IDs cannot change network settings",
      requires: %{device: [], fixture: []}
    }
  end

  def run(%{device: device}) do
    before = Device.status(device)
    assert before.device.available

    for command <- [:confirm, :cancel] do
      assert {:error, %{code: "invalid_parameters"}} =
               Device.rpc(device, NervesGate.Network, command, [nil])
    end

    after_status = Device.status(device)
    assert after_status.device.available
    assert after_status.network.desired == before.network.desired
    assert after_status.network.pending == before.network.pending
  end
end

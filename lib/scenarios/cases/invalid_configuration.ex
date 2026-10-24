defmodule Scenarios.Cases.InvalidConfiguration do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.Device, as: Device

  def spec do
    %{
      name: "Invalid configuration is rejected without changing settings",
      requires: %{device: [], fixture: []}
    }
  end

  def run(%{device: device}) do
    before = Device.status(device)
    assert before.device.available
    invalid = %{"mode" => "not-a-mode"}

    assert {:error, %{code: "invalid_parameters"}} =
             Scenarios.Device.rpc(device, NervesGate.Network, :validate, [invalid])

    assert {:error, %{code: "invalid_parameters"}} =
             Scenarios.Device.rpc(device, NervesGate.Network, :propose, [invalid])

    after_rejection = Device.status(device)
    assert after_rejection.device.available
    assert after_rejection.network.desired == before.network.desired
    assert after_rejection.network.pending == before.network.pending
  end
end

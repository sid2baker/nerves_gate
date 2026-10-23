defmodule Dev.Scenarios.InvalidConfiguration do
  @moduledoc false
  import ExUnit.Assertions
  alias Dev.TestDevice, as: Device

  def spec do
    %{
      name: "Invalid configuration is rejected without changing settings",
      requires: %{device: [], fixture: []}
    }
  end

  def run(%{device: device}) do
    before = Device.status(device)
    assert before.backend.available
    invalid = %{"mode" => "not-a-mode"}

    assert {:error, %{code: "invalid_parameters"}} =
             Device.call(device, :network_validate, [invalid])

    assert {:error, %{code: "invalid_parameters"}} =
             Device.call(device, :network_propose, [invalid])

    after_rejection = Device.status(device)
    assert after_rejection.backend.available
    assert after_rejection.network.desired == before.network.desired
    assert after_rejection.network.pending == before.network.pending
  end
end

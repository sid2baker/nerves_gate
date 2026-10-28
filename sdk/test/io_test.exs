defmodule NervesGateSDK.IOTest do
  use ExUnit.Case, async: true
  alias NervesGateSDK.IO.{InputDefinition, Observation, OutputDefinition}

  test "state-only definitions have no command or event delivery fields" do
    input = %InputDefinition{id: "temperature", type: :float}
    assert input.unit == nil
    assert input.expected_interval_ms == nil

    output = %OutputDefinition{id: "enable", type: :boolean}

    assert Map.keys(Map.from_struct(output)) |> Enum.sort() ==
             Enum.sort([:id, :type, :unit, :min, :max, :feedback_input_id])
  end

  test "observations retain false values and nullable UTC without request references" do
    observation = %Observation{
      input_id: "pump.enabled",
      value: false,
      quality: :good,
      received_at_ms: -123
    }

    assert observation.value === false
    assert observation.received_at_utc == nil
    refute Map.has_key?(observation, :ref)
  end
end

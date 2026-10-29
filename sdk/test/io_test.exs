defmodule NervesGateSDK.IOTest do
  use ExUnit.Case, async: true
  alias NervesGateSDK.IO.{Evidence, InputDefinition, OutputDefinition, Reading}

  defmodule Unused do
    @behaviour NervesGateSDK.Output
    @impl true
    def apply(_, _, state), do: {:applied, state}
  end

  test "state-only definitions have no command or event delivery fields" do
    input = %InputDefinition{id: "temperature", type: :float}
    assert input.unit == nil
    assert input.expected_interval_ms == nil

    output = %OutputDefinition{id: "enable", type: :boolean}
    assert output.evidence == []
    assert output.on_release == nil

    assert Map.keys(Map.from_struct(output)) |> Enum.sort() ==
             Enum.sort([:id, :type, :unit, :min, :max, :on_release, :evidence])
  end

  test "evidence defaults to immediate equality" do
    evidence = %Evidence{input: "modbus_plugin.pump.enabled", role: :readback}
    assert evidence.settle_ms == 0
    assert evidence.expect == :equals
  end

  test "readings retain false values and nullable UTC without request references" do
    reading = %Reading{
      input_id: "pump.enabled",
      value: false,
      quality: :good,
      received_at_ms: -123
    }

    assert reading.value === false
    assert reading.received_at_utc == nil
    refute Map.has_key?(reading, :ref)
  end

  test "the output runtime registers before applying and fails without firmware" do
    Process.flag(:trap_exit, true)
    definition = %OutputDefinition{id: "enable", type: :boolean}

    assert {:error, {:registration_failed, "enable", :runtime_unavailable}} =
             NervesGateSDK.Output.start_link(Unused, [definition], nil)
  end
end

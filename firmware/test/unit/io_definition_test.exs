defmodule NervesGate.IODefinitionTest do
  # Catalog persistence uses the globally named NervesGate.Settings table.
  use ExUnit.Case, async: false
  alias NervesGate.IO.{Catalog, Definition}
  alias NervesGate.Settings
  alias NervesGateSDK.IO.{Evidence, InputDefinition, OutputDefinition, Reading}

  @moduletag :tmp_dir

  test "strict types, units, IDs and bounds" do
    input = %InputDefinition{id: "room.temperature", type: :float}
    output = %OutputDefinition{id: "setpoint", type: :float, min: 0.0, max: 40.0}
    assert Definition.valid?(input)
    assert Definition.valid?(output)
    assert Definition.desired?(output, 0.0)
    assert Definition.desired?(output, 40.0)
    refute Definition.desired?(output, 40)
    refute Definition.desired?(output, 41.0)

    for id <- [
          "",
          "Room",
          "1room",
          "room..value",
          "room.",
          "other/value",
          String.duplicate("a", 129),
          :temperature
        ] do
      refute Definition.valid?(%{input | id: id})
    end

    for unit <- ["", :celsius, <<255>>, String.duplicate("a", 33)] do
      refute Definition.valid?(%{input | unit: unit})
    end

    for interval <- [0, -1, 1.0, "100"] do
      refute Definition.valid?(%{input | expected_interval_ms: interval})
    end

    refute Definition.valid?(%{input | type: :event})
    refute Definition.valid?(Map.put(input, :kind, :event))
    refute Definition.valid?(%{output | min: 0})
    refute Definition.valid?(%{output | min: 50.0})
    refute Definition.valid?(%OutputDefinition{id: "relay", type: :boolean, min: 0})
    assert Definition.value?(:boolean, false)
    refute Definition.value?(:boolean, 0)
    assert Definition.value?(:string, "")
    assert Definition.value?(:string, String.duplicate("x", 1024))
    refute Definition.value?(:string, String.duplicate("x", 1025))
    refute Definition.value?(:string, <<255>>)
    refute Definition.value?(:integer, "1")
    refute Definition.value?(:integer, 1.0)
  end

  test "evidence and release declarations use a closed, type-checked set" do
    output = %OutputDefinition{id: "setpoint", type: :float, min: 0.0, max: 40.0}
    readback = %Evidence{input: "modbus_plugin.room.temperature", role: :readback}
    relay = %OutputDefinition{id: "relay", type: :boolean}

    for valid <- [
          %{output | evidence: [readback]},
          %{output | evidence: [%{readback | expect: {:tolerance, 0.5}, settle_ms: 3_600_000}]},
          %{output | on_release: :hold},
          %{output | on_release: {:value, 0.0}},
          %{relay | evidence: [%{readback | role: :physical, expect: %{true => {:above, 1.0}}}]},
          %{
            relay
            | evidence: [%{readback | role: :estimate, expect: %{false => {:equals, "off"}}}]
          }
        ] do
      assert Definition.valid?(valid)
    end

    for invalid <- [
          %{output | evidence: readback},
          %{output | evidence: [readback, readback]},
          %{output | evidence: List.duplicate(readback, 9)},
          %{output | evidence: [%{readback | input: "temperature"}]},
          %{output | evidence: [%{readback | input: "Bad.id"}]},
          %{output | evidence: [%{readback | role: :command}]},
          %{output | evidence: [%{readback | settle_ms: -1}]},
          %{output | evidence: [%{readback | settle_ms: 3_600_001}]},
          %{output | evidence: [%{readback | expect: {:tolerance, -1}}]},
          %{output | evidence: [%{readback | expect: %{true => {:above, 1}}}]},
          %{output | evidence: [Map.put(readback, :extra, true)]},
          %{output | on_release: {:value, 41.0}},
          %{output | on_release: :close},
          %{relay | evidence: [%{readback | expect: {:tolerance, 1}}]},
          %{relay | evidence: [%{readback | expect: %{}}]},
          %{relay | evidence: [%{readback | expect: %{1 => {:above, 1}}}]},
          %{relay | evidence: [%{readback | expect: %{true => {:near, 1}}}]}
        ] do
      refute Definition.valid?(invalid)
    end
  end

  test "freshness uses monotonic receipt only; no interval has no age threshold" do
    input = %InputDefinition{id: "temperature", type: :float, expected_interval_ms: 100}

    sample = %Reading{
      input_id: "test.temperature",
      value: 21.0,
      quality: :good,
      received_at_ms: -1_000
    }

    refute Definition.stale?(input, sample, -900)
    assert Definition.stale?(input, sample, -899)
    refute Definition.stale?(%{input | expected_interval_ms: nil}, sample, 1_000_000)
    refute Definition.stale?(input, nil, 1_000_000)
  end

  test "persisted definitions survive a restart of the settings table", %{tmp_dir: dir} do
    start_supervised!({Settings, path: dir})

    definitions = %{
      "test.temperature" => %InputDefinition{
        id: "temperature",
        type: :integer,
        expected_interval_ms: 1000
      },
      "test.setpoint" => %OutputDefinition{
        id: "setpoint",
        type: :integer,
        min: 0,
        max: 100,
        on_release: {:value, 0},
        evidence: [
          %Evidence{
            input: "test.temperature",
            role: :readback,
            settle_ms: 500,
            expect: {:tolerance, 1}
          }
        ]
      }
    }

    assert {:ok, %{}} = Catalog.load()
    assert :ok = Catalog.save(definitions)
    stop_supervised!(Settings)
    start_supervised!({Settings, path: dir})
    assert {:ok, ^definitions} = Catalog.load()
  end

  test "catalog rejects unsupported and malformed definitions without rewriting them",
       %{tmp_dir: dir} do
    start_supervised!({Settings, path: dir})
    input = %InputDefinition{id: "temperature", type: :float}
    malformed = input |> Map.delete(:id) |> Map.put(:wrong_field, "temperature")
    too_many = Map.new(1..1025, &{"test.value#{&1}", %{input | id: "value#{&1}"}})
    assert {:error, :io_catalog_full} = Catalog.save(too_many)

    for saved <- [
          "broken",
          %{schema: 2, definitions: %{"test.temperature" => input}},
          %{"wrong.id" => input},
          %{"test.temperature" => malformed},
          too_many
        ] do
      :ok = Settings.put(["io", "definitions"], saved)
      assert {:error, :invalid_io_catalog} = Catalog.load()
      assert Settings.get(["io", "definitions"]) == saved
    end
  end
end

defmodule NervesGate.IODefinitionTest do
  use ExUnit.Case, async: true
  alias NervesGate.IO.{Catalog, Definition}
  alias NervesGateSDK.IO.{InputDefinition, Observation, OutputDefinition}

  @moduletag :tmp_dir

  test "strict types, units, IDs, bounds and feedback IDs" do
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
    refute Definition.valid?(%{output | feedback_input_id: "Bad"})
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

  test "freshness uses monotonic receipt only; no interval has no age threshold" do
    input = %InputDefinition{id: "temperature", type: :float, expected_interval_ms: 100}

    sample = %Observation{
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

  test "catalog rejects corrupt, trailing, compressed, unsupported and malformed data without rewriting",
       %{tmp_dir: dir} do
    path = Path.join(dir, "io.term")
    assert {:ok, %{}} = Catalog.load(path)
    input = %InputDefinition{id: "temperature", type: :float}
    definitions = %{"test.temperature" => input}
    assert :ok = Catalog.save(path, definitions)
    assert {:ok, ^definitions} = Catalog.load(path)
    valid = File.read!(path)
    malformed = input |> Map.delete(:id) |> Map.put(:wrong_field, "temperature")

    documents = [
      "broken",
      valid <> "trailing",
      :erlang.term_to_binary(%{schema: 2, definitions: definitions}),
      :erlang.term_to_binary(%{schema: 1, definitions: definitions, desire: true}),
      :erlang.term_to_binary(%{schema: 1, definitions: %{"wrong.id" => input}}),
      :erlang.term_to_binary(%{schema: 1, definitions: %{"test.temperature" => malformed}}),
      :erlang.term_to_binary(%{schema: 1, definitions: definitions}, compressed: 9),
      :erlang.term_to_binary(%{
        schema: 1,
        definitions: Map.new(1..1025, &{"test.value#{&1}", %{input | id: "value#{&1}"}})
      }),
      :binary.copy(<<0>>, 1024 * 1024 + 1)
    ]

    for bytes <- documents do
      File.write!(path, bytes)
      assert {:error, :invalid_io_catalog} = Catalog.load(path)
      assert File.read!(path) == bytes
    end

    File.rm!(path)
    File.mkdir_p!(path)
    assert {:error, :invalid_io_catalog} = Catalog.load(path)
  end
end

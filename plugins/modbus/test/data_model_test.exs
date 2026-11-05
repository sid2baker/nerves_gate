defmodule ModbusPlugin.DataModelTest do
  use ExUnit.Case, async: true
  alias ModbusPlugin.{Codec, Config, Endpoint, Plan, Profiles, Server, Store}

  defp params(mappings, extra \\ %{}),
    do:
      Map.merge(
        %{
          "role" => "client",
          "transport" => "tcp",
          "host" => "127.0.0.1",
          "port" => 502,
          "unit" => 1,
          "interval" => 500,
          "timeout" => 100,
          "mappings" => mappings
        },
        extra
      )

  defp point(type, extra \\ %{}),
    do: Map.merge(%{"id" => "point", "table" => "holding", "address" => 0, "type" => type}, extra)

  defp mapping(type, extra \\ %{}) do
    {:ok, %{mappings: [mapping]}} = Config.validate("one", params([point(type, extra)]))
    mapping
  end

  test "all four tables, typed endpoint definitions and exact normalized restoration" do
    for table <- ~w(coil discrete holding input) do
      {:ok, config} =
        Config.validate("one", params([%{"id" => "p", "table" => table, "address" => 0}]))

      assert Store.valid?(%{"one" => config})
      assert Config.validate("one", Config.params(config)) == {:ok, config}
      [batch] = Plan.build(config)
      assert Plan.request(batch) == {Plan.function(hd(config.mappings).table), 0, 1}
    end

    m = point("s32", %{"access" => "write", "scale" => -0.1, "unit" => "W"})
    {:ok, config} = Config.validate("one", params([m]))

    assert [%{type: :float, unit: "W", min: -214_748_364.7, max: 214_748_364.8}] =
             Endpoint.outputs(config)
  end

  test "every datatype round-trips and signed boundaries and word ordering are exact" do
    cases = [
      {"bool", %{}, false, [0]},
      {"bool", %{}, true, [1]},
      {"u16", %{}, 65535, [65535]},
      {"s16", %{}, -32768, [32768]},
      {"u32", %{}, 4_294_967_295, [65535, 65535]},
      {"s32", %{}, -2_147_483_648, [32768, 0]},
      {"u32", %{"word_order" => "low_first"}, 65536, [0, 1]},
      {"s32", %{"word_order" => "low_first"}, -65536, [0, 65535]},
      {"float32", %{}, 12.3, [16708, 52429]},
      {"float32", %{}, 3.4028235e38, [32639, 65535]},
      {"float32", %{}, -3.4028235e38, [65407, 65535]},
      {"float32", %{"word_order" => "low_first"}, -1.5, [0, 49088]},
      {"ascii", %{"length" => 3}, "ABC", [16706, 17152, 0]},
      {"s16", %{"scale" => 0.1}, -12.3, [65413]},
      {"s16", %{"scale" => -10}, 1230, [65413]}
    ]

    for {type, extra, value, words} <- cases do
      mapping = mapping(type, extra)
      assert Codec.encode(mapping, value) == {:ok, words}
      assert Codec.decode(mapping, words) == {:ok, value}
    end

    assert Codec.decode(mapping("bool", %{"bit" => 3}), [8]) == {:ok, true}
    assert Codec.decode(mapping("bool", %{"bit" => 3}), [4]) == {:ok, false}
    assert Codec.decode(mapping("ascii", %{"length" => 2}), [16706, 8224]) == {:ok, "AB"}
    assert Codec.parse(mapping("float32"), "12.3") == 12.3
    assert Codec.parse(mapping("ascii", %{"length" => 2}), "123") == "123"
  end

  test "encoding rejects out-of-range, wrong types and values that would not read back equal" do
    for {m, value} <- [
          {mapping("u16"), -1},
          {mapping("u16"), 65536},
          {mapping("u16"), 1.0},
          {mapping("s16"), 32768},
          {mapping("s32"), -2_147_483_649},
          {mapping("float32"), 1},
          {mapping("float32"), 1.0e39},
          {mapping("float32", %{"scale" => 0.000001}), 1.0e308},
          {mapping("u16", %{"scale" => 0.000001}), 1.0e308},
          {mapping("float32"), 1.23456789123},
          {mapping("u16", %{"scale" => 0.1}), 1.23},
          {mapping("u16", %{"scale" => 10}), 11},
          {mapping("ascii", %{"length" => 1}), "ABC"},
          {mapping("ascii", %{"length" => 2}), "A\x00B"}
        ] do
      assert Codec.encode(m, value) == {:error, :invalid_value}
    end

    for words <- [[32704, 0], [32640, 0], [65408, 0]] do
      assert Codec.decode(mapping("float32"), words) == {:error, :not_a_number}
    end

    assert Codec.decode(mapping("ascii", %{"length" => 1}), [65535]) == {:error, :invalid_text}
  end

  test "validation reports the mapping and meaningful reason, not a generic failure" do
    cases = [
      {point("s64"), {:invalid_type, "s64"}},
      {point("u16", %{"table" => "other"}), {:unsupported_table, "other"}},
      {point("u32", %{"address" => 65535}), {:span_out_of_range, 65535}},
      {point("u16", %{"address" => 70000}), {:address_out_of_range, 70000}},
      {point("u16", %{"address" => "junk"}), {:address_out_of_range, "junk"}},
      {point("u16", %{"table" => "input", "access" => "write"}), {:not_writable, :input}},
      {point("bool", %{"table" => "discrete", "access" => "write"}), {:not_writable, :discrete}},
      {point("s16", %{"table" => "coil"}), {:type_not_allowed, :s16, :coil}},
      {point("bool", %{"bit" => 16}), {:invalid_bit, 16}},
      {point("bool", %{"bit" => 0, "access" => "write"}), :bit_is_read_only},
      {point("u16", %{"scale" => 0}), {:invalid_scale, 0}},
      {point("u16", %{"direction" => "input"}), {:unknown_field, "direction"}},
      {point("ascii", %{"length" => 124}), {:invalid_length, 124}},
      {point("u32", %{"word_order" => "dcba"}), {:invalid_word_order, "dcba"}}
    ]

    for {point, reason} <- cases do
      assert Config.validate("one", params([point])) ==
               {:error, {:invalid_mapping, "point", reason}}
    end

    assert {:error, {:invalid_mapping, "point", :duplicate_id}} =
             Config.validate("one", params([point("u16"), point("s16")]))

    assert {:error, {:invalid_mapping, "two", {:overlaps, "point"}}} =
             Config.validate(
               "one",
               params([
                 point("u32", %{"access" => "write"}),
                 point("u16", %{"id" => "two", "address" => 1, "access" => "write"})
               ])
             )

    assert {:error, {:invalid_mapping, "set", {:incompatible_feedback, "point"}}} =
             Config.validate(
               "one",
               params([
                 point("u16"),
                 point("s32", %{
                   "id" => "set",
                   "access" => "write",
                   "scale" => 0.1,
                   "feedback" => "point"
                 })
               ])
             )
  end

  test "poll plan merges only bounded overlapping or adjacent reads and decodes slices" do
    mappings = [
      point("u16", %{"id" => "a"}),
      point("s32", %{"id" => "b", "address" => 1}),
      point("bool", %{"id" => "flag", "address" => 1, "bit" => 15}),
      point("u16", %{"id" => "gap", "address" => 4}),
      point("u16", %{"id" => "set", "address" => 10, "access" => "write"}),
      point("u16", %{"id" => "input", "table" => "input"})
    ]

    {:ok, config} = Config.validate("one", params(mappings))
    batches = Plan.build(config)

    assert Enum.map(batches, &{&1.table, &1.address, &1.count}) == [
             {:holding, 0, 3},
             {:holding, 4, 1},
             {:input, 0, 1}
           ]

    [{_, {:ok, 7}}, {_, {:ok, -2}}, {_, {:ok, true}}] =
      Plan.decode(hd(batches), [7, 65535, 65534])

    assert Enum.map(Plan.build(%{config | max_gap: 1}), & &1.count) == [5, 1]

    mappings = for n <- 0..63, do: point("u32", %{"id" => "p#{n}", "address" => n * 2})
    {:ok, config} = Config.validate("one", params(mappings))
    assert Enum.map(Plan.build(config), & &1.count) == [124, 4]
  end

  test "server owns a raw four-table map, validates multi-register writes atomically" do
    {:ok, config} =
      Config.validate("one", params([point("s32", %{"initial" => -2})], %{"role" => "server"}))

    [mapping] = config.mappings

    state = %{
      config: config,
      map: %{{:holding, 0} => 65535, {:holding, 1} => 65534},
      values: %{"point" => -2}
    }

    assert {:reply, {:ok, [65535, 65534]}, ^state} =
             Server.handle_call({:request, 1, {:read_holding_registers, 0, 2}}, nil, state)

    assert {:reply, :ok, next} =
             Server.handle_call(
               {:request, 1, {:write_multiple_registers, 0, [0, 42]}},
               nil,
               state
             )

    assert next.values[mapping.id] == 42

    assert {:reply, {:error, {:exception, :illegal_data_address}}, ^state} =
             Server.handle_call(
               {:request, 1, {:write_multiple_registers, 1, [0, 42]}},
               nil,
               state
             )

    assert {:reply, {:error, {:exception, :gateway_path_unavailable}}, ^state} =
             Server.handle_call({:request, 2, {:read_holding_registers, 0, 1}}, nil, state)
  end

  test "empty client definitions are discovery-only and oversized initial floats fail cleanly" do
    assert {:ok, config} = Config.validate("one", params([]))
    assert Store.valid?(%{"one" => config})
    state = %{configs: %{"one" => config}, monitors: %{}, error: nil}

    assert {:reply, {:error, :no_mappings}, ^state} =
             ModbusPlugin.handle_call({:start, "one"}, {self(), make_ref()}, state)

    assert {:error, {:invalid_field, "mappings", 0}} =
             Config.validate("one", params([], %{"role" => "server"}))

    huge = Integer.pow(10, 400)

    assert {:error, {:invalid_mapping, "point", {:invalid_initial, ^huge}}} =
             Config.validate(
               "one",
               params([point("float32", %{"initial" => huge})], %{"role" => "server"})
             )
  end

  test "templates are ordinary validated read-only mappings and SunSpec is evidence-based" do
    assert {:ok, _} = Config.validate("solis", params(Profiles.solis()))
    assert Profiles.sunspec(%{id: 2, address: 0, length: 66}) == []

    assert {:ok, config} =
             Config.validate(
               "sun",
               params(Profiles.sunspec(%{id: 1, address: 40002, length: 66}))
             )

    assert Enum.all?(config.mappings, &(&1.access == :read and &1.type == :ascii))
  end
end

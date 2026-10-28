defmodule ModbusPlugin.StoreTest do
  use ExUnit.Case, async: true
  alias ModbusPlugin.{Config, Store}

  test "definitions validate into a bounded map without persisting" do
    assert {:ok, configs} = Store.put(%{}, "pump", params())
    assert {:ok, config} = Config.validate("pump", params())
    assert configs == %{"pump" => config}
    assert Store.valid?(configs)

    assert {:error, :invalid_configuration} =
             Store.put(configs, "pump", %{params() | "unit" => 0})

    full = Enum.reduce(1..16, %{}, fn n, acc -> elem(Store.put(acc, "d#{n}", params()), 1) end)
    assert {:error, :device_limit} = Store.put(full, "overflow", params())
    assert {:ok, replaced} = Store.put(full, "d1", %{params() | "unit" => 2})
    assert replaced["d1"].unit == 2
  end

  test "restored terms must validate exactly; runtime fields never gain authority" do
    {:ok, config} = Config.validate("pump", params())

    for configs <- [
          [],
          %{"other" => config},
          %{"pump" => Map.put(config, :serial_path, "/dev/ttyS0")},
          %{"pump" => Map.put(config, :serial_monitor, make_ref())},
          %{"pump" => %{config | unit: 0}},
          %{"pump" => %{config | mappings: [:not_a_map]}},
          Map.new(1..17, &{"d#{&1}", %{config | id: "d#{&1}"}})
        ] do
      refute Store.valid?(configs)
    end
  end

  test "without the platform, restore and persist report the SDK error" do
    assert {:error, {:storage_unavailable, :runtime_unavailable}} = Store.restore()
    assert {:error, :runtime_unavailable} = Store.persist(%{})
  end

  defp params do
    %{
      "role" => "client",
      "transport" => "tcp",
      "host" => "127.0.0.1",
      "port" => 502,
      "unit" => 1,
      "interval" => 500,
      "timeout" => 1000,
      "mappings" => [
        %{"id" => "level", "table" => "holding", "address" => 0, "direction" => "input"}
      ]
    }
  end
end

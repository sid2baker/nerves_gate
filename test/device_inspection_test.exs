defmodule Workbench.DeviceInspectionTest do
  use ExUnit.Case, async: true
  alias Workbench.DeviceInspection
  alias Workbench.DeviceInspection.Logs

  test "local target does not start distribution" do
    before = Node.alive?()
    assert {:ok, node} = DeviceInspection.connect(Node.self())
    assert node == Node.self()
    assert Node.alive?() == before
  end

  test "filters by minimum level" do
    assert [%{message: "warning", level: :warning}] =
             Logs.format([entry(:info, "info"), entry(:warning, "warning")], :warning)

    assert length(Logs.format([entry(:info, "info")], :debug)) == 1
  end

  test "strips session data, credentials, URLs and crash-state dumps" do
    entries = [
      entry(
        :error,
        "failure at https://example.test/private-login\n  Parameters: hidden\n  Session: hidden-session"
      ),
      entry(
        :error,
        "GenServer terminating\n** (MatchError) nil\n  lib/example.ex:19\nLast message: private\nState: private-state"
      ),
      entry(
        :warning,
        "cookie: never-return-this\nuseful warning\nauthorization: never-return-this"
      )
    ]

    rows = Logs.format(entries, :warning)
    output = inspect(rows)

    for secret <- [
          "private-login",
          "hidden",
          "private-state",
          "never-return-this",
          "Last message"
        ] do
      refute output =~ secret
    end

    assert output =~ "[url]"
    assert output =~ "MatchError"
    assert output =~ "lib/example.ex:19"
    assert output =~ "useful warning"
    assert Enum.all?(rows, &(Enum.sort(Map.keys(&1)) == [:index, :level, :message, :timestamp]))
  end

  test "caps message bytes and preserves valid UTF-8" do
    rows = Logs.format(List.duplicate(entry(:error, String.duplicate("€", 3_000)), 30), :warning)
    assert Enum.all?(rows, &(String.valid?(&1.message) and byte_size(&1.message) <= 2_000))
    assert Enum.sum(Enum.map(rows, &byte_size(&1.message))) <= 16_000
  end

  test "invalid requests do not attempt a connection" do
    assert {:error, :invalid_node} = DeviceInspection.connect("not-a-node")
    assert {:error, :invalid_node} = DeviceInspection.connect(123)
    assert {:error, :invalid_node} = DeviceInspection.connect(String.duplicate("x", 256))

    for opts <- [[limit: 0], [limit: 101], [level: :invalid]] do
      assert {:error, :invalid_log_options} = DeviceInspection.logs("not-a-node", opts)
    end
  end

  defp entry(level, text) do
    %{
      level: level,
      message: text,
      timestamp: {{2026, 10, 27}, {12, 0, 0, 0}},
      metadata: [index: 42]
    }
  end
end

defmodule Workbench.MuonTrapTest do
  use ExUnit.Case, async: false

  test "captured output is complete and cannot kill the caller at command exit" do
    Process.flag(:trap_exit, true)
    expected = Enum.map_join(1..13_000, "\n", &Integer.to_string/1) <> "\n"

    results =
      Task.async_stream(
        1..1_000,
        fn _ -> MuonTrap.cmd("seq", ["1", "13000"], stderr_to_stdout: true, timeout: 10_000) end,
        max_concurrency: 64,
        timeout: 15_000
      )

    for result <- results do
      assert {:ok, {^expected, 0}} = result
    end
  end
end

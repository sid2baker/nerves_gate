defmodule Dev.FirmwareCommandTest do
  use ExUnit.Case, async: true
  alias Dev.FirmwareCommand

  test "short commands can exit immediately without an output-acknowledgement EPIPE" do
    printf = System.find_executable("printf")
    output = "Flash Info:\n\tFlash Size: 7471104 Sectors\n"

    for _ <- 1..500 do
      assert FirmwareCommand.run(printf, ["%s", output], timeout: 2_000) == {output, 0}
    end
  end

  test "captures output larger than MuonTrap's normal flow-control window" do
    output = String.duplicate("x", 64_000)
    assert FirmwareCommand.run(System.find_executable("printf"), ["%s", output]) == {output, 0}
  end

  test "nonzero command status is preserved without retry" do
    assert {"", 1} = FirmwareCommand.run(System.find_executable("false"), [])
  end

  @tag :tmp_dir
  test "timeout stops the owned OS command", %{tmp_dir: dir} do
    path = Path.join(dir, "child.pid")
    task = Task.async(fn -> sleeping_command(path, 1_000) end)
    await(fn -> File.exists?(path) end)
    pid = File.read!(path)
    assert Task.await(task, 5_000) == {"", :timeout}
    await(fn -> not File.exists?("/proc/#{pid}") end)
  end

  @tag :tmp_dir
  test "killing the command owner closes its port and stops its owned OS command", %{tmp_dir: dir} do
    path = Path.join(dir, "child.pid")
    {worker, ref} = spawn_monitor(fn -> sleeping_command(path, 5_000) end)
    on_exit(fn -> Process.exit(worker, :kill) end)
    await(fn -> File.exists?(path) end)
    pid = File.read!(path)
    Process.exit(worker, :kill)
    assert_receive {:DOWN, ^ref, :process, ^worker, :killed}
    await(fn -> not File.exists?("/proc/#{pid}") end)
  end

  defp sleeping_command(path, timeout) do
    script = "File.write!(#{inspect(path)}, System.pid()); Process.sleep(:infinity)"

    FirmwareCommand.run(
      System.find_executable("elixir"),
      ["--erl", "+S 1:1 +SDio 1 +SDcpu 1", "-e", script],
      timeout: timeout,
      stderr_to_stdout: true
    )
  end

  defp await(fun, attempts \\ 100)
  defp await(fun, 0), do: assert(fun.())

  defp await(fun, attempts) do
    unless fun.() do
      Process.sleep(25)
      await(fun, attempts - 1)
    end
  end
end

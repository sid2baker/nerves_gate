defmodule NervesGate.Firmware.CommandTest do
  use ExUnit.Case, async: true

  alias NervesGate.Firmware.Command

  test "returns command results" do
    runner = fn executable, arguments, options ->
      {executable <> Enum.join(arguments) <> inspect(options), 0}
    end

    assert {:ok, {output, 0}} = Command.run(runner, "fwup", ["-V"], timeout: 1_000)
    assert output =~ "fwup-V"
  end

  test "converts an abnormal linked runner exit to a typed error" do
    caller = self()
    runner = fn _executable, _arguments, _options -> Process.exit(self(), :port_setup_failed) end

    assert {:error, :command_crashed} = Command.run(runner, "fwup", [], timeout: 1_000)
    assert Process.alive?(caller)
  end

  test "terminates a command that exceeds its bound" do
    runner = fn _executable, _arguments, _options -> Process.sleep(:infinity) end

    assert {:error, :command_timeout} = Command.run(runner, "fwup", [], timeout: 10)
  end
end

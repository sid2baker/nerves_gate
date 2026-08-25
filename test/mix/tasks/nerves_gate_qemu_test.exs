defmodule Mix.Tasks.NervesGate.QemuTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "prints help without starting the standalone tool" do
    for argument <- ["help", "--help", "-h"] do
      output = capture_io(fn -> Mix.Tasks.NervesGate.Qemu.run([argument]) end)

      assert output =~ "Usage:"
      assert output =~ "mix nerves_gate.qemu observe [DEVICE|all] [--json]"
      assert output =~ "mix nerves_gate.qemu help"
    end
  end
end

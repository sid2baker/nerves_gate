defmodule Mix.Tasks.QemuTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  test "prints command help for every conventional help argument" do
    for argument <- ["help", "--help", "-h"] do
      output = capture_io(fn -> Mix.Tasks.Qemu.run([argument]) end)

      assert output =~ "Usage:"
      assert output =~ "mix qemu observe [DEVICE|all] [--json]"
      assert output =~ "mix qemu help"
    end
  end
end

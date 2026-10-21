defmodule Mix.Tasks.Test.Qemu do
  use Mix.Task
  @shortdoc "Run real QEMU scenarios on the owned bench"
  @requirements ["app.config"]
  def run(args), do: Dev.QemuCLI.run(args)
end

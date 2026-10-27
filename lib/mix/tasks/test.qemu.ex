defmodule Mix.Tasks.Test.Qemu do
  use Mix.Task
  @shortdoc "Run QEMU scenarios on the running mix dev session, or a disposable --ci bench"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.test_qemu(args)
end

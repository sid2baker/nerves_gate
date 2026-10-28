defmodule Mix.Tasks.Scenario.Run do
  use Mix.Task
  @shortdoc "Run an explicit scenario on an explicit verified target"
  @moduledoc "Run `mix scenario.run ID --device TARGET`. QEMU cases use Runner; physical checks use Jobs and only the physical catalogue. Explicit `all` runs the non-opt-in QEMU catalogue, never physical procedures. Cases may reset disposable disks; inspect `mix scenario.list` and authorize the run first."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Scenario.run(args)
end

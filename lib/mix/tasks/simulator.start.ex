defmodule Mix.Tasks.Simulator.Start do
  use Mix.Task
  @shortdoc "Start the session's explicitly configured owned QEMU devices"
  @moduledoc "Run `mix simulator.start` with the user-owned Workbench running and private networking prepared. May build local firmware. Waits for completion; never starts physical devices."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Simulator.run("start", args)
end

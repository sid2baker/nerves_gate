defmodule Mix.Tasks.Simulator.Reset do
  use Mix.Task
  @shortdoc "Confirm erasure of all owned simulated device disks"
  @moduledoc "Run `mix simulator.reset [--confirm]`. Prompts before erasing every owned simulated disk/settings. --confirm records explicit noninteractive authorization. Waits for completion; never resets physical gateways."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Simulator.run("reset", args)
end

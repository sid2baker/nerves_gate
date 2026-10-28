defmodule Mix.Tasks.Simulator.Stop do
  use Mix.Task
  @shortdoc "Stop owned QEMU devices, preserving their disks"
  @moduledoc "Run `mix simulator.stop`. Requires the current Workbench session and lifecycle admission. Waits for completion; does not stop Workbench or unrelated VMs."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Simulator.run("stop", args)
end

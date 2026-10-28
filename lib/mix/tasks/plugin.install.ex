defmodule Mix.Tasks.Plugin.Install do
  use Mix.Task
  @shortdoc "Install a plugin on a running simulated device"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.plugin(:install, args)
end

defmodule Mix.Tasks.App.Install do
  use Mix.Task
  @shortdoc "Install an application on a running simulated device"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.app(:install, args)
end

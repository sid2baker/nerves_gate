defmodule Mix.Tasks.App.Install do
  use Mix.Task
  @shortdoc "Install an application on an owned simulated device"
  @requirements ["app.config"]
  def run(args), do: Workbench.AppCLI.run(:install, args)
end

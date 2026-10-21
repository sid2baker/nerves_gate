defmodule Mix.Tasks.App.Install do
  use Mix.Task
  @shortdoc "install an application in a separate solution"
  @requirements ["app.config"]
  def run(args), do: Dev.AppCLI.run(:install, args)
end

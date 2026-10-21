defmodule Mix.Tasks.App.Package do
  use Mix.Task
  @shortdoc "package an application in a separate solution"
  @requirements ["app.config"]
  def run(args), do: Dev.AppCLI.run(:package, args)
end

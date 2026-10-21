defmodule Mix.Tasks.App.New do
  use Mix.Task
  @shortdoc "new an application in a separate solution"
  @requirements ["app.config"]
  def run(args), do: Dev.AppCLI.run(:new, args)
end

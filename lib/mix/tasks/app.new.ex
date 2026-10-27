defmodule Mix.Tasks.App.New do
  use Mix.Task
  @shortdoc "Create an ordinary SDK application project"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.app(:new, args)
end

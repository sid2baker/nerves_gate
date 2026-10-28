defmodule Mix.Tasks.Plugin.New do
  use Mix.Task
  @shortdoc "Create an ordinary SDK plugin project"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.plugin(:new, args)
end

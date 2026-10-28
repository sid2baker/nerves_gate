defmodule Mix.Tasks.Plugin.Test do
  use Mix.Task
  @shortdoc "Run host tests for a plugin directory"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.plugin(:test, args)
end

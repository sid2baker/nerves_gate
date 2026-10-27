defmodule Mix.Tasks.App.Test do
  use Mix.Task
  @shortdoc "Run host tests for an application directory"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.app(:test, args)
end

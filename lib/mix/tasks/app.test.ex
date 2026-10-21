defmodule Mix.Tasks.App.Test do
  use Mix.Task
  @shortdoc "test an application in a separate solution"
  @requirements ["app.config"]
  def run(args), do: Dev.AppCLI.run(:test, args)
end

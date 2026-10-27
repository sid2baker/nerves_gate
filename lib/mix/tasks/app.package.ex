defmodule Mix.Tasks.App.Package do
  use Mix.Task
  @shortdoc "Package an application directory with the SDK"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.app(:package, args)
end

defmodule Mix.Tasks.Plugin.Package do
  use Mix.Task
  @shortdoc "Package a plugin directory with the SDK"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.plugin(:package, args)
end

defmodule Mix.Tasks.Plugin.Package do
  use Mix.Task
  @shortdoc "Package a plugin directory with the SDK"
  @moduledoc "Run `mix plugin.package PATH`. Builds the independent plugin's SDK archive under its build-output lock. Requires no Workbench session, installs nothing and does not bump immutable plugin versions."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Plugin.run(:package, args)
end

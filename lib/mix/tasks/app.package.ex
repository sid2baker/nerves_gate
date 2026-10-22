defmodule Mix.Tasks.App.Package do
  use Mix.Task
  @shortdoc "Package an application directory with the SDK"
  @requirements ["app.config"]
  def run(args), do: Dev.AppCLI.run(:package, args)
end

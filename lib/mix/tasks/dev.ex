defmodule Mix.Tasks.Dev do
  use Mix.Task
  @shortdoc "Open the developer workbench without starting devices"
  @requirements ["app.config"]
  def run(args), do: Dev.Launcher.run(args)
end

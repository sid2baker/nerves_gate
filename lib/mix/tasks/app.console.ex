defmodule Mix.Tasks.App.Console do
  use Mix.Task
  @shortdoc "Print the console command for an idle manually reserved device"
  @requirements ["app.config"]
  def run(args), do: Workbench.Console.run(args)
end

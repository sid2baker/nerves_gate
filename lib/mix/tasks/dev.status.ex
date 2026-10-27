defmodule Mix.Tasks.Dev.Status do
  use Mix.Task
  @shortdoc "Show this checkout's Workbench session"
  @requirements ["app.config"]
  def run([]), do: IO.puts(Workbench.Session.describe())
end

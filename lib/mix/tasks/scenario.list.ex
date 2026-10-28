defmodule Mix.Tasks.Scenario.List do
  use Mix.Task
  @shortdoc "List scenario IDs, target kinds and requirements without a session"
  @moduledoc "Run `mix scenario.list`. Reads the local catalogue only; no device operations."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Scenario.list(args)
end

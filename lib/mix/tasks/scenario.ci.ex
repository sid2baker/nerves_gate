defmodule Mix.Tasks.Scenario.Ci do
  use Mix.Task
  @shortdoc "Run a scenario in a separately owned disposable QEMU bench"
  @moduledoc "Run `mix scenario.ci ID --device ID [--config PATH]`. Explicitly launches and cleans up another bench with disposable disks. Requires prepared networking and authorization; never selects a first device implicitly."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Scenario.ci(args)
end

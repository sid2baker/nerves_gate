defmodule Mix.Tasks.Gateway.List do
  use Mix.Task
  @shortdoc "List this session's verified gateway directory"
  @moduledoc "Run `mix gateway.list`. Shows physical/network and owned-QEMU identities, connectivity and explicit target identifiers. Never boots or controls devices."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Gateway.list(args)
end

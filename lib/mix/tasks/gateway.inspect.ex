defmodule Mix.Tasks.Gateway.Inspect do
  use Mix.Task
  @shortdoc "Read identity, status, plugins and hardware of an explicit gateway"
  @moduledoc "Run `mix gateway.inspect TARGET`. TARGET is a connected node, address or simulator ID from `mix gateway.list`. Reads are bounded and non-atomic; no controls are sent."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Gateway.inspect_gateway(args)
end

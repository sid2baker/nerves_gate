defmodule Mix.Tasks.Plugin.Test do
  use Mix.Task
  @shortdoc "Run host tests for a plugin directory"
  @moduledoc "Run `mix plugin.test PATH`. Fetches dependencies and runs host tests in isolated OS processes under the plugin's build-output lock. Requires no Workbench session and opens no devices implicitly."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Plugin.run(:test, args)
end

defmodule Mix.Tasks.Plugin.New do
  use Mix.Task
  @shortdoc "Create an ordinary SDK plugin project"
  @moduledoc "Run `mix plugin.new PATH [--local-sdk]`. Creates an independent project without starting or requiring Workbench. --local-sdk selects this checkout's prerelease SDK; otherwise uses the published SDK. Never overwrites an existing path."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Plugin.run(:new, args)
end

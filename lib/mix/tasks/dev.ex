defmodule Mix.Tasks.Dev do
  use Mix.Task
  @shortdoc "Open the developer workbench without starting devices"
  @moduledoc "Run `mix dev [PLUGIN_DIRECTORY] [--config PATH | --firmware IMAGE] [--port PORT]`. Starts only this checkout's localhost Workbench session. Devices remain stopped; networking must be prepared explicitly. The user owns this long-running session. Disposable scenario benches use `mix scenario.ci`, not flags to this command."
  @requirements ["app.config"]
  def run(args), do: Workbench.Launcher.dev(args)
end

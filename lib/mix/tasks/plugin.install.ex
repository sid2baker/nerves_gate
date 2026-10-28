defmodule Mix.Tasks.Plugin.Install do
  use Mix.Task
  @shortdoc "Install a plugin on an explicit verified QEMU or physical target"
  @moduledoc "Run `mix plugin.install PATH --device TARGET`. Requires the running Workbench; packages under Jobs admission and holds owned-QEMU reservations before packaging. Physical targets require review and interactive confirmation; installation never blindly retries an uncertain transfer."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Plugin.run(:install, args)
end

defmodule Mix.Tasks.Dev.Job do
  use Mix.Task
  @shortdoc "Inspect current/recent Jobs and Runner operations"
  @moduledoc "Run `mix dev.job [ID]` against this checkout's session. IDs include the session and owner. A wait timeout does not cancel work; inspect rather than replay. History is bounded and lost with the owner/session."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Diagnostics.job(args)
end

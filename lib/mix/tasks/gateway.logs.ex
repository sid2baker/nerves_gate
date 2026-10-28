defmodule Mix.Tasks.Gateway.Logs do
  use Mix.Task
  @shortdoc "Read a bounded sanitized gateway log snapshot"
  @moduledoc "Run `mix gateway.logs TARGET [--limit 1..100]`. Default 50 entries at warning or above; capped at 16 KB. This is not live streaming. QEMU serial logs provide live output."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Gateway.logs(args)
end

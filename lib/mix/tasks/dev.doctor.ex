defmodule Mix.Tasks.Dev.Doctor do
  use Mix.Task
  @shortdoc "Read checkout/session compatibility without changing anything"
  @moduledoc "Run `mix dev.doctor`. Reports tools, recorded network preparation and session compatibility. Never repairs, builds or starts devices."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Diagnostics.doctor(args)
end

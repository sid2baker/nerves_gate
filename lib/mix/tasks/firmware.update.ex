defmodule Mix.Tasks.Firmware.Update do
  use Mix.Task
  @shortdoc "Review and apply firmware to a connected physical gateway"
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.firmware_update(args)
end

defmodule Mix.Tasks.Firmware.Update do
  use Mix.Task
  @shortdoc "Review and apply firmware to a connected physical gateway"
  @moduledoc "Run `mix firmware.update TARGET [IMAGE] [--sha256 SHA]`. Requires the verified Workbench session. Defaults to the dev image built for the gateway's board (EC100 or EM300). Reviews identity, health, immutable plugin artifacts and SSH trust; prompts before a single upload. --sha256 approves only that exact reviewed image. Waits for a healthy new boot. Never builds, retries an uncertain upload or changes plugin selections."
  @requirements ["app.config"]
  def run(args), do: Workbench.CLI.Firmware.run(args)
end

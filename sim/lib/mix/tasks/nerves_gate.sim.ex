defmodule Mix.Tasks.NervesGate.Sim do
  @moduledoc """
  Start the QEMU simulator site. Devices remain stopped until explicitly started
  in the site. Applications use the real firmware SDK backend inside the guest;
  this task never starts the current application against fake host hardware.

      mix nerves_gate.sim [--firmware path/to/nerves_gate.fw] [--port 4000]

  In the repository, the default configuration builds the local QEMU firmware.
  Outside the repository, supply a compatible prebuilt firmware with --firmware.
  """
  @shortdoc "Start the Nerves Gate QEMU simulator"
  use Mix.Task

  @impl true
  def run(args), do: Mix.Task.run("qemu.dev", args)
end

defmodule Mix.Tasks.NervesGate.Qemu do
  @shortdoc "Runs and observes the standalone NervesGate QEMU topology"

  @moduledoc """
  Delegates QEMU lifecycle and observation commands to the standalone host tool.

      mix nerves_gate.qemu setup --count 3
      mix nerves_gate.qemu status
      mix nerves_gate.qemu observe
      mix nerves_gate.qemu logs
  """

  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    NervesGateQEMUTool.prepare!()
    NervesGateQEMUTool.run!(["qemu" | arguments])
  end
end

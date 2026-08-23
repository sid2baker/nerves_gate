defmodule Mix.Tasks.NervesGate.Dev do
  @shortdoc "Starts the independent NervesGate QEMU development server"

  @moduledoc """
  Starts the standalone host control plane at
  `http://qemu.localhost:4000/dev/qemu`.

      mix nerves_gate.dev
  """

  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    NervesGateQEMUTool.prepare!()
    NervesGateQEMUTool.run!(["phx.server" | arguments])
  end
end

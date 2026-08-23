defmodule Mix.Tasks.NervesGate.QemuCi do
  @moduledoc false
  @shortdoc false

  use Mix.Task

  @impl Mix.Task
  def run(_arguments) do
    NervesGateQEMUTool.prepare!()
    NervesGateQEMUTool.run!(["ci"], env: "test")
  end
end

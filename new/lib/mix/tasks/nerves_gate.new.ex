defmodule Mix.Tasks.NervesGate.New do
  use Mix.Task
  @shortdoc "Generate a Nerves Gate app-development workspace"
  @moduledoc """
  `mix nerves_gate.new my_workspace` creates a workspace with one independent
  SDK application, simulator configuration, and short local Mix commands. It
  never fetches dependencies, boots devices or formats cards.
  """

  @impl true
  def run([path]) do
    NervesGateNew.workspace(path)

    Mix.shell().info("""

    Next:
      cd #{path}
      mix setup

    Copy a compatible x86_64 QEMU image to firmware/nerves_gate.fw,
    or edit config/simulator.exs to select your image. Then:
      mix sim

    Start devices on the site, open the gateway UI, and choose
    Application storage → Use this card. In another terminal:
      mix app.install my_app
      mix app.package my_app
      mix app.new telemetry
      mix setup
      mix test
    """)
  end

  def run(_), do: Mix.raise("Usage: mix nerves_gate.new my_workspace")
end

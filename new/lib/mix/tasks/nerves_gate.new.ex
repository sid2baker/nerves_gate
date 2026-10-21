defmodule Mix.Tasks.NervesGate.New do
  use Mix.Task
  @shortdoc "Generate a Nerves Gate app-development workspace"
  @moduledoc """
  `mix nerves_gate.new my_workspace` creates a workspace with one independent
  SDK application, simulator configuration, and short local Mix commands. It
  never fetches dependencies, boots devices or formats cards.
  """

  @impl true
  def run([path, "--local", source]) do
    source = Path.expand(source)

    unless File.regular?(Path.join(source, "sdk/mix.exs")),
      do: Mix.raise("Not a Nerves Gate checkout: #{source}")

    generate(path, source)
  end

  def run([path]), do: generate(path, nil)
  def run(_), do: Mix.raise("Usage: mix nerves_gate.new my_workspace")

  defp generate(path, source) do
    NervesGateNew.workspace(path, source)

    Mix.shell().info("""

    Next:
      cd #{path}
      mix setup

    Setup downloads and verifies the default QEMU firmware if missing.
    Existing images and custom paths in config/simulator.exs are preserved.
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
end

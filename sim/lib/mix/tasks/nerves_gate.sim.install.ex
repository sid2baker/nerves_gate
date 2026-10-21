defmodule Mix.Tasks.NervesGate.Sim.Install do
  @moduledoc """
  Package the current application and run it on a simulator device.

      mix nerves_gate.sim.install [device] [--package app.ez]

  Requires a running `mix nerves_gate.sim` session in this directory with
  started devices. The package goes through the device's real application
  manager and virtual SD card. Reinstalling replaces the development copy and
  preserves the application's data directory.
  """
  @shortdoc "Install the current application on a QEMU simulator device"
  use Mix.Task

  @impl true
  def run(args) do
    {options, devices, invalid} = OptionParser.parse(args, strict: [package: :string])

    if invalid != [],
      do: Mix.raise("Usage: mix nerves_gate.sim.install [device] [--package app.ez]")

    {client, state} =
      NervesGateSim.DevSession.connect("_build/qemu-dev", 180_000) ||
        Mix.raise(
          "Start the simulator in this directory first (mix sim in a generated workspace)."
        )

    device =
      case {devices, state["lifecycle"]["devices"]} do
        {[device], _} -> device
        {[], [%{"id" => first} | _]} -> first
        {[], _} -> Mix.raise("Start the simulator devices first.")
        _ -> Mix.raise("Usage: mix nerves_gate.sim.install [device]")
      end

    package =
      if options[:package] do
        path = Path.expand(options[:package])

        unless Path.extname(path) == ".ez" and File.regular?(path),
          do: Mix.raise("Expected an existing .ez package")

        path
      else
        config = Mix.Project.config()
        path = Path.expand("_build/nerves_gate_sim/#{config[:app]}-#{config[:version]}.ez")
        File.mkdir_p!(Path.dirname(path))
        File.rm(path)
        Mix.Task.run("nerves_gate.package", ["--output", path])
        path
      end

    case Req.post!(client, url: "/api/install", form: [device: device, package: package]) do
      %{status: 200, body: %{"id" => id}} ->
        Mix.shell().info("Install ##{id} on #{device}; live results on /devices/#{device}")
        Mix.Tasks.Qemu.Test.wait(client, id, MapSet.new())

      %{status: 200, body: %{"error" => error}} ->
        Mix.raise(error)

      %{status: status} ->
        Mix.raise("Simulator API unavailable (HTTP #{status})")
    end
  end
end

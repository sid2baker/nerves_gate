defmodule Mix.Tasks.NervesGate.Sim.Install do
  @moduledoc """
  Package the current application and run it on a simulator device.

      mix nerves_gate.sim.install [device]

  Requires a running `mix nerves_gate.sim` session in this directory with
  started devices. The package goes through the device's real application
  manager and virtual SD card. Reinstalling replaces the development copy and
  preserves the application's data directory.
  """
  @shortdoc "Install the current application on a QEMU simulator device"
  use Mix.Task

  @impl true
  def run(args) do
    {client, state} =
      NervesGate.DevSession.connect("_build/qemu-dev", 180_000) ||
        Mix.raise("Start mix nerves_gate.sim in this directory first.")

    device =
      case {args, state["lifecycle"]["devices"]} do
        {[device], _} -> device
        {[], [%{"id" => first} | _]} -> first
        {[], _} -> Mix.raise("Start the simulator devices first.")
        _ -> Mix.raise("Usage: mix nerves_gate.sim.install [device]")
      end

    config = Mix.Project.config()
    package = Path.expand("_build/nerves_gate_sim/#{config[:app]}-#{config[:version]}.ez")
    File.mkdir_p!(Path.dirname(package))
    File.rm(package)
    Mix.Task.run("nerves_gate.package", ["--output", package])

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

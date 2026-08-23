defmodule Mix.Tasks.NervesGate.Qemu do
  @shortdoc "Runs the three-node NervesGate QEMU environment"

  @moduledoc """
  Starts a fresh three-node environment for commissioning:

      mix nerves_gate.qemu setup

  Lifecycle commands preserve the current disks and settings slots:

      mix nerves_gate.qemu start
      mix nerves_gate.qemu status
      mix nerves_gate.qemu stop
      mix nerves_gate.qemu restart
      mix nerves_gate.qemu reset
  """

  use Mix.Task

  @lifecycle ~w(start stop restart reset status prepare)

  @impl Mix.Task
  def run(arguments) do
    case List.first(arguments) || "setup" do
      "setup" -> fresh_environment()
      action when action in @lifecycle -> lifecycle(action, Enum.at(arguments, 1, "all"))
      _other -> Mix.raise("expected setup or #{Enum.join(@lifecycle, ", ")}")
    end
  end

  defp fresh_environment do
    ensure_firmware!()
    run_script("reset", "all")
    run_script("start", "all")
    Mix.shell().info("Fresh commissioning pages ready on ports 4001–4003 at /commissioning")
  end

  defp lifecycle(action, target) do
    if action in ["start", "restart", "prepare", "reset"], do: ensure_firmware!()
    run_script(action, target)
  end

  defp run_script(action, target) do
    script = Path.expand("scripts/three_node_qemu.sh")

    case System.cmd(script, [action, target], into: IO.stream(), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("QEMU command failed with status #{status}")
    end
  end

  defp ensure_firmware! do
    firmware = Path.expand("_build/x86_64_dev/nerves/images/nerves_gate.fw")

    unless File.exists?(firmware) do
      Mix.shell().info("Building x86_64 firmware first…")

      case System.cmd("mix", ["firmware"],
             env: [{"MIX_TARGET", "x86_64"}],
             into: IO.stream(),
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {_output, status} -> Mix.raise("firmware build failed with status #{status}")
      end
    end
  end
end

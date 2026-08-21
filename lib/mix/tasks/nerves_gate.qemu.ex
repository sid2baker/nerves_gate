defmodule Mix.Tasks.NervesGate.Qemu do
  @shortdoc "Runs three persistent x86_64 NervesGate VMs"

  @moduledoc """
  Starts, stops, or resets the three-node local QEMU environment.

      mix nerves_gate.qemu
      mix nerves_gate.qemu status
      mix nerves_gate.qemu stop
      mix nerves_gate.qemu reset

  Setup pages are forwarded to http://127.0.0.1:4001/setup through :4003.
  Disks persist in `tmp/qemu` until `reset` is used.
  """

  use Mix.Task

  @actions ~w(start stop restart reset status prepare)

  @impl Mix.Task
  def run(arguments) do
    action = List.first(arguments) || "start"
    target = Enum.at(arguments, 1, "all")

    unless action in @actions do
      Mix.raise("expected one of: #{Enum.join(@actions, ", ")}")
    end

    if action in ["start", "restart", "prepare", "reset"], do: ensure_firmware!()

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

      env = [{"MIX_TARGET", "x86_64"}]

      case System.cmd("mix", ["firmware"], env: env, into: IO.stream(), stderr_to_stdout: true) do
        {_output, 0} -> :ok
        {_output, status} -> Mix.raise("firmware build failed with status #{status}")
      end
    end
  end
end

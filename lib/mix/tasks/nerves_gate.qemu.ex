defmodule Mix.Tasks.NervesGate.Qemu do
  @shortdoc "Runs and observes the standalone NervesGate QEMU topology"

  @usage """
  Usage:
    mix nerves_gate.qemu setup [--count N] [--rebuild]
    mix nerves_gate.qemu add
    mix nerves_gate.qemu remove DEVICE
    mix nerves_gate.qemu start|stop|restart|reset [DEVICE|all]
    mix nerves_gate.qemu status [DEVICE|all]
    mix nerves_gate.qemu observe [DEVICE|all] [--json]
    mix nerves_gate.qemu logs [DEVICE|all]
    mix nerves_gate.qemu prepare [DEVICE|all]
    mix nerves_gate.qemu help

  With no command, `setup --count 3` is used. Pass `--rebuild` to build current
  source before recreating every disk. Start, stop, and restart preserve disks.
  """

  @moduledoc """
  Delegates QEMU lifecycle and observation commands to the standalone host tool.

  #{@usage}
  """

  use Mix.Task

  @help_arguments ~w(help --help -h)

  @impl Mix.Task
  def run([argument | _rest]) when argument in @help_arguments,
    do: Mix.shell().info(@usage)

  def run(arguments) do
    NervesGateQEMUTool.prepare!()
    NervesGateQEMUTool.run!(["qemu" | arguments])
  end
end

defmodule Mix.Tasks.NervesGate.Dev do
  @shortdoc "Starts the independent NervesGate QEMU development server"

  @moduledoc """
  Starts the standalone host control plane at
  `http://qemu.localhost:4000/`.

      mix nerves_gate.dev
  """

  use Mix.Task

  @impl Mix.Task
  def run(arguments) do
    NervesGateQEMUTool.prepare!()
    NervesGateQEMUTool.run_server!(arguments)
  end
end

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

defmodule NervesGateQEMUTool do
  @moduledoc false

  def prepare! do
    unless File.dir?(Path.join(project_path(), "deps/phoenix")) do
      Mix.shell().info("Installing standalone QEMU tool dependencies…")
      run!(["deps.get", "--quiet"])
    end

    :ok
  end

  def run!(arguments, options \\ []) do
    run_command!("mix", arguments, options)
  end

  def run_server!(arguments \\ []) do
    environment = [{"MIX_ENV", "dev"}]

    case MuonTrap.cmd("mix", ["phx.server" | arguments],
           cd: project_path(),
           env: environment,
           into: IO.stream(),
           stderr_to_stdout: true,
           delay_to_sigkill: 2_000
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("QEMU development server failed with status #{status}")
    end
  end

  defp run_command!(executable, arguments, options) do
    environment = [{"MIX_ENV", Keyword.get(options, :env, "dev")}]

    case System.cmd(executable, arguments,
           cd: project_path(),
           env: environment,
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("QEMU tool command failed with status #{status}")
    end
  end

  defp project_path do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join("tools/nerves_gate_qemu")
    |> Path.expand()
  end
end

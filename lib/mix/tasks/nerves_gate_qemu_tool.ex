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
    environment = [{"MIX_ENV", Keyword.get(options, :env, "dev")}]

    case System.cmd("mix", arguments,
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

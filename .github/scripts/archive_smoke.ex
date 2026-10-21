defmodule NervesGate.ArchiveSmoke do
  @moduledoc false

  # Installation must run in a new VM outside the checkout. Calling the task's
  # already-loaded module would hide missing archive modules and template files.
  def run!(archive) do
    root = Path.join(System.tmp_dir!(), "gate_archive_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)

    env = [
      {"MIX_HOME", Path.join(root, "mix")},
      {"MIX_ARCHIVES", Path.join(root, "archives")},
      {"MIX_ENV", "prod"},
      {"MIX_TARGET", "host"}
    ]

    try do
      command!(["archive.install", Path.expand(archive), "--force"], root, env)
      command!(["nerves_gate.new", "workspace"], root, env)
      workspace = Path.join(root, "workspace")

      for relative <- [
            "mix.exs",
            "config/simulator.exs",
            ".gitignore",
            ".formatter.exs",
            "apps/my_app/mix.exs",
            "apps/my_app/.gitignore",
            "apps/my_app/.formatter.exs"
          ] do
        unless File.regular?(Path.join(workspace, relative)),
          do: raise("Installed generator did not create #{relative}")
      end

      for path <- Path.wildcard(Path.join(workspace, "**/*.{ex,exs}"), match_dot: true),
          do: path |> File.read!() |> Code.string_to_quoted!()

      :ok
    after
      File.rm_rf!(root)
    end
  end

  defp command!(args, root, env) do
    case System.cmd("mix", args, cd: root, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {output, status} -> raise "Archive smoke failed (#{status}): #{output}"
    end
  end
end

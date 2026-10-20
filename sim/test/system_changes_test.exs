defmodule NervesGateSim.SystemChangesTest do
  use ExUnit.Case, async: false
  @script Path.expand("../../.github/scripts/system_changes.exs", __DIR__)

  test "CI detects each system independently, including deletions and first pushes" do
    dir = Path.join(System.tmp_dir!(), "system_changes_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    keys = ~w(EVENT_NAME PR_BASE_SHA PUSH_BASE_SHA GITHUB_OUTPUT)
    previous = Map.new(keys, &{&1, System.get_env(&1)})

    try do
      git!(dir, ["init", "--quiet"])
      File.write!(Path.join(dir, "README.md"), "fixture")
      initial = commit!(dir)
      ec100 = Path.join(dir, "systems/nerves_system_ec100/VERSION")
      qemu = Path.join(dir, "systems/nerves_system_ec100_qemu/VERSION")
      File.mkdir_p!(Path.dirname(ec100))
      File.mkdir_p!(Path.dirname(qemu))
      File.write!(ec100, "0.2.1")
      ec100_commit = commit!(dir)
      assert detect!(dir, "push", initial) == "system=false\nec100=true\n"
      File.write!(qemu, "0.2.2")
      qemu_commit = commit!(dir)
      assert detect!(dir, "pull_request", ec100_commit) == "system=true\nec100=false\n"
      File.rm!(ec100)
      commit!(dir)
      assert detect!(dir, "push", qemu_commit) == "system=false\nec100=true\n"
      assert detect!(dir, "push", String.duplicate("0", 40)) == "system=true\nec100=true\n"
      assert detect!(dir, "workflow_dispatch", "HEAD") == "system=false\nec100=false\n"
    after
      for {key, value} <- previous do
        if value, do: System.put_env(key, value), else: System.delete_env(key)
      end

      File.rm_rf!(dir)
    end
  end

  defp detect!(dir, event, base) do
    output = Path.join(dir, "outputs")
    File.write!(output, "")
    System.put_env("EVENT_NAME", event)
    System.put_env("PUSH_BASE_SHA", base)
    System.put_env("PR_BASE_SHA", base)
    System.put_env("GITHUB_OUTPUT", output)
    File.cd!(dir, fn -> Code.eval_file(@script) end)
    File.read!(output)
  end

  defp commit!(dir) do
    git!(dir, ["add", "--all"])

    git!(dir, [
      "-c",
      "user.name=Test",
      "-c",
      "user.email=test@example.invalid",
      "commit",
      "--quiet",
      "-m",
      "Fixture"
    ])

    git!(dir, ["rev-parse", "HEAD"]) |> String.trim()
  end

  defp git!(dir, args) do
    {output, status} = System.cmd("git", args, cd: dir, stderr_to_stdout: true)
    assert status == 0, output
    output
  end
end

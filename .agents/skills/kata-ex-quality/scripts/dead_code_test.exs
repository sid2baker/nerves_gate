ExUnit.start()

defmodule DeadCode.CLITest do
  use ExUnit.Case, async: true

  @script Path.expand("dead_code.exs", __DIR__)
  @template Path.expand("../assets/dead-code-roots.exs", __DIR__)

  setup do
    root = Path.join(System.tmp_dir!(), "kata-dead-code-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(root, "lib/workers"))
    on_exit(fn -> File.rm_rf!(root) end)

    File.write!(Path.join(root, "lib/api.ex"), "defmodule Demo.API do\nDemo.Live.run()\nend")
    File.write!(Path.join(root, "lib/live.ex"), "defmodule Demo.Live do\ndef run, do: :ok\nend")
    File.write!(Path.join(root, "lib/workers/job.ex"), "defmodule Demo.Job do\nend")
    File.write!(Path.join(root, "lib/dead.ex"), "defmodule Demo.Dead do\nend")
    {:ok, root: root}
  end

  test "the bundled template works explicitly and as the fallback", %{root: root} do
    {explicit, 0} = run(root, ["--roots", @template])
    assert {explicit, 0} == run(root)
    assert dead_paths(explicit) == all_paths()
  end

  test "literal roots preserve public paths, reachability, comments, and globs", %{root: root} do
    roots = Path.join(root, "roots.exs")

    File.write!(roots, """
    # Paths and reasons are data.
    %{
      public_api: ["lib/api.ex"],
      roots: [{"lib/workers/*.ex", "Started by name"}]
    }
    """)

    {output, 0} = run(root, ["--roots", roots])
    assert dead_paths(output) == ["lib/dead.ex"]
  end

  test "literal roots can omit unused keys", %{root: root} do
    roots = Path.join(root, "roots.exs")

    File.write!(roots, ~s(%{public_api: ["lib/api.ex"]}))
    {output, 0} = run(root, ["--roots", roots])
    assert dead_paths(output) == ["lib/dead.ex", "lib/workers/job.ex"]

    File.write!(roots, "%{}")
    {output, 0} = run(root, ["--roots", roots])
    assert dead_paths(output) == all_paths()
  end

  test "both existing project roots locations still work", %{root: root} do
    for relative <- [
          ".kata/dead-code-roots.exs",
          ".agents/skills/kata-ex-hunt-dead-code/roots.exs"
        ] do
      roots = Path.join(root, relative)
      File.mkdir_p!(Path.dirname(roots))
      File.write!(roots, ~s(%{public_api: ["lib/api.ex"], roots: []}))
      {output, 0} = run(root)
      assert dead_paths(output) == ["lib/dead.ex", "lib/workers/job.ex"]
      File.rm!(roots)
    end
  end

  test "rejects code and invalid data without executing it", %{root: root} do
    roots = Path.join(root, "roots.exs")
    marker = Path.join(root, "executed")
    write = "File.write!(#{inspect(marker)}, \"executed\")"

    for source <- [
          write <> "\n%{roots: [], public_api: []}",
          "%{roots: [], public_api: [#{write}]}",
          ~S(%{roots: [{"lib/dead.ex", "#{) <> write <> ~S(}"}]}),
          "%{roots: [], public_api: []} |> Map.new()",
          "%{kata_unknown_manifest_key_7f4c2e: []}",
          "%{public_api: [\"lib/api.ex\"], public_api: [], roots: []}",
          "%{roots: [\"lib/dead.ex\"]}",
          "%{public_api: [123]}",
          "%{roots: ["
        ] do
      File.write!(roots, source)
      {output, status} = run(root, ["--roots", roots])
      refute File.exists?(marker), "Executed roots file: #{source}"
      assert status != 0, "Accepted invalid roots file: #{source}"
      assert output =~ "Invalid roots file: #{roots}"
    end
  end

  defp run(root, args \\ []) do
    System.cmd(System.find_executable("elixir"), [@script, "--root", root, "--json"] ++ args,
      stderr_to_stdout: true
    )
  end

  defp dead_paths(output) do
    output |> JSON.decode!() |> Map.fetch!("clusters") |> List.flatten() |> Enum.sort()
  end

  defp all_paths, do: ["lib/api.ex", "lib/dead.ex", "lib/live.ex", "lib/workers/job.ex"]
end

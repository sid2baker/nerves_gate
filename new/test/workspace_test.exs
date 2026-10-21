defmodule NervesGateNew.WorkspaceTest do
  use ExUnit.Case, async: false
  alias NervesGateNew.Workspace

  @sdk Path.expand("../../sdk", __DIR__)

  test "workspace selects and packages independent apps, restoring the root project" do
    path = Path.join(System.tmp_dir!(), "gate_workspace_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(path) end)
    NervesGateNew.workspace(path)
    firmware = Path.join(path, "firmware/nerves_gate.fw")
    File.write!(firmware, "existing image")
    File.write!(Path.join(path, "config/simulator.exs"), inspect(%{firmware: firmware}))
    local_sdk!(Path.join(path, "apps/my_app/mix.exs"))
    previous = Mix.Project.pop()
    compiler = Code.compiler_options()
    paths = :code.get_path()

    try do
      Code.compiler_options(ignore_module_conflict: true)

      Mix.Project.in_project(:generated_workspace, path, fn _ ->
        project = Mix.Project.get()
        Mix.Local.append_archives()

        archives =
          Enum.filter(
            :code.get_path(),
            &String.starts_with?(to_string(&1), Mix.path_for(:archives))
          )

        assert archives != []
        Mix.Local.remove_archives()
        Workspace.setup([])
        assert Enum.all?(archives, &(&1 in :code.get_path()))
        assert Mix.Project.get() == project
        assert_raise Mix.Error, ~r/Unknown app/, fn -> Workspace.package(["missing"]) end
        assert_raise Mix.Error, fn -> Workspace.new(["../escape"]) end
        File.rm!(firmware)
        assert_raise Mix.Error, ~r/Run mix setup/, fn -> Workspace.sim([]) end
        File.write!(firmware, "existing image")

        Workspace.package([])
        assert Mix.Project.get() == project
        package = Path.join(path, "packages/my_app-1.0.0.ez")
        assert {:ok, files} = :zip.extract(String.to_charlist(package), [:memory])
        names = Enum.map(files, fn {name, _} -> to_string(name) end)
        assert "my_app-1.0.0/ebin/my_app.app" in names

        refute Enum.any?(
                 names,
                 &String.contains?(&1, ["nerves_gate_sim", "nerves_gate_sdk", "workspace"])
               )

        assert_raise Mix.Error, ~r/Refusing to overwrite/, fn -> Workspace.package([]) end

        Workspace.new(["telemetry_app"])
        local_sdk!(Path.join(path, "apps/telemetry_app/mix.exs"))
        Workspace.setup([])
        assert_raise Mix.Error, ~r/Choose an app/, fn -> Workspace.package([]) end
        Workspace.package(["telemetry_app", "--output", "telemetry.ez"])
        assert File.regular?(Path.join(path, "telemetry.ez"))
        assert Mix.Project.get() == project
      end)
    after
      Code.compiler_options(compiler)
      :code.set_path(paths)
      Mix.Project.push(previous.name, previous.file)
    end
  end

  # Exercise generated projects with the local SDK before Hex publication. This
  # is test fixture configuration, not a dependency on firmware or simulator code.
  defp local_sdk!(file) do
    source = File.read!(file)

    source =
      String.replace(
        source,
        "{:nerves_gate_sdk, \"~> 0.1.0\"}",
        "{:nerves_gate_sdk, path: #{inspect(@sdk)}}"
      )

    File.write!(file, source)
  end
end

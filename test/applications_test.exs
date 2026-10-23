defmodule Dev.ApplicationsTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  test "the workbench creates and opens a standalone SDK app without a manifest", %{tmp_dir: dir} do
    path = Path.join(dir, "telemetry")
    assert {:ok, app} = Dev.Workbench.application("new", path)
    assert app.path == path
    assert app in Dev.Applications.list()
    assert File.read!(Path.join(path, "mix.exs")) =~ "{:nerves_gate_sdk, \"~> 0.1.0\"}"
    refute File.exists?(Path.join(path, "nerves_gate.exs"))
    assert File.exists?(Path.join(path, ".formatter.exs"))
    assert File.exists?(Path.join(path, ".gitignore"))
    assert {:ok, ^app} = Dev.Workbench.application("open", path)
    assert {:error, message} = Dev.Workbench.application("new", path)
    assert message =~ "overwrite"
    assert {:error, _} = Dev.Workbench.application("open", dir)
    assert {:error, _} = Dev.Workbench.application("open", Dev.root())

    for name <- ["Uppercase", "bad-name", "nerves_gate_dev", "nerves_gate_sdk", "dev"] do
      assert_raise ArgumentError, fn -> Dev.Applications.new!(Path.join(dir, name)) end
    end

    for file <- Path.wildcard(Path.join(path, "**/*.{ex,exs}"), match_dot: true) do
      contents = File.read!(file)
      assert contents == IO.iodata_to_binary(Code.format_string!(contents)) <> "\n", file
    end
  end

  test "local SDK app builds and packages without loading application code", %{tmp_dir: dir} do
    app = Dev.Applications.new!(Path.join(dir, "sample_app"), true)

    assert File.read!(Path.join(app.path, "mix.exs")) =~
             "path: #{inspect(Path.join(Dev.root(), "sdk"))}"

    project = Mix.Project.get()
    paths = :code.get_path()
    env = System.get_env()
    assert :ok = Dev.Applications.test!(app.path)
    package = Dev.Applications.package!(app.path)
    assert {:ok, info} = NervesGateSDK.Package.read_binary(File.read!(package))
    assert info.app == :sample_app
    assert Mix.Project.get() == project
    assert :code.get_path() == paths
    assert System.get_env() == env
    refute Code.ensure_loaded?(SampleApp)
    assert_raise RuntimeError, fn -> Dev.Applications.package!(app.path) end
  end

  test "scenario catalog stays owned by the simulator and loaded by the platform" do
    ids = Enum.map(Simulator.QemuTests.scenarios(), & &1.id)
    assert "apps" in ids and "sdk" in ids and "public_status" in ids
  end
end

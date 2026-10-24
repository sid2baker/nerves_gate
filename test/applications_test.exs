defmodule Workbench.ApplicationsTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  test "the workbench creates and opens a standalone SDK app without a manifest", %{tmp_dir: dir} do
    path = Path.join(dir, "telemetry")
    assert {:ok, app} = Workbench.Applications.create(path)
    assert app.path == path
    assert app in Workbench.Applications.list()
    assert File.read!(Path.join(path, "mix.exs")) =~ "{:nerves_gate_sdk, \"~> 0.1.0\"}"
    refute File.exists?(Path.join(path, "nerves_gate.exs"))
    assert File.exists?(Path.join(path, ".formatter.exs"))
    assert File.exists?(Path.join(path, ".gitignore"))
    assert {:ok, ^app} = Workbench.Applications.open(path)
    assert {:error, message} = Workbench.Applications.create(path)
    assert message =~ "overwrite"
    assert {:error, _} = Workbench.Applications.open(dir)
    assert {:error, _} = Workbench.Applications.open(Workbench.root())

    for name <- ["Uppercase", "bad-name", "nerves_gate_workbench", "nerves_gate_sdk", "dev"] do
      assert_raise ArgumentError, fn -> Workbench.Applications.scaffold!(Path.join(dir, name)) end
    end

    for file <- Path.wildcard(Path.join(path, "**/*.{ex,exs}"), match_dot: true) do
      contents = File.read!(file)
      assert contents == IO.iodata_to_binary(Code.format_string!(contents)) <> "\n", file
    end
  end

  test "local SDK app builds and packages without loading application code", %{tmp_dir: dir} do
    app = Workbench.Applications.scaffold!(Path.join(dir, "sample_app"), local_sdk: true)

    assert File.read!(Path.join(app.path, "mix.exs")) =~
             "path: #{inspect(Path.join(Workbench.root(), "sdk"))}"

    project = Mix.Project.get()
    paths = :code.get_path()
    env = System.get_env()
    assert :ok = Workbench.Applications.test!(app.path)
    package = Workbench.Applications.package!(app.path)
    assert {:ok, info} = NervesGateSDK.Package.read_binary(File.read!(package))
    assert info.app == :sample_app
    assert Mix.Project.get() == project
    assert :code.get_path() == paths
    assert System.get_env() == env
    refute Code.ensure_loaded?(SampleApp)
    assert_raise RuntimeError, fn -> Workbench.Applications.package!(app.path) end
  end

  test "the single scenario catalogue is loaded by the workbench" do
    ids = Enum.map(Scenarios.all(), & &1.id)
    assert "apps" in ids and "sdk" in ids and "public_status" in ids
  end
end

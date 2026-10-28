defmodule Workbench.PluginsTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    on_exit(fn -> File.rm_rf!(dir) end)
    :ok
  end

  test "the workbench creates and opens a standalone SDK plugin without a manifest", %{
    tmp_dir: dir
  } do
    path = Path.join(dir, "telemetry")
    assert {:ok, plugin} = Workbench.Plugins.create(path)
    assert plugin.path == path
    assert plugin in Workbench.Plugins.list()
    assert File.read!(Path.join(path, "mix.exs")) =~ "{:nerves_gate_sdk, \"~> 0.2.0-dev\"}"
    refute File.exists?(Path.join(path, "nerves_gate.exs"))
    assert File.exists?(Path.join(path, ".formatter.exs"))
    assert File.exists?(Path.join(path, ".gitignore"))
    assert {:ok, ^plugin} = Workbench.Plugins.open(path)
    assert {:error, message} = Workbench.Plugins.create(path)
    assert message =~ "overwrite"
    assert {:error, _} = Workbench.Plugins.open(dir)
    assert {:error, _} = Workbench.Plugins.open(Workbench.root())

    for name <- ["Uppercase", "bad-name", "nerves_gate_workbench", "nerves_gate_sdk", "dev"] do
      assert_raise ArgumentError, fn -> Workbench.Plugins.scaffold!(Path.join(dir, name)) end
    end

    for file <- Path.wildcard(Path.join(path, "**/*.{ex,exs}"), match_dot: true) do
      contents = File.read!(file)
      assert contents == IO.iodata_to_binary(Code.format_string!(contents)) <> "\n", file
    end
  end

  test "local SDK plugin builds and packages without loading plugin code", %{tmp_dir: dir} do
    plugin = Workbench.Plugins.scaffold!(Path.join(dir, "sample_app"), local_sdk: true)

    assert File.read!(Path.join(plugin.path, "mix.exs")) =~
             "path: #{inspect(Path.join(Workbench.root(), "sdk"))}"

    project = Mix.Project.get()
    paths = :code.get_path()
    env = System.get_env()
    assert :ok = Workbench.Plugins.test!(plugin.path)
    package = Workbench.Plugins.package!(plugin.path)
    assert {:ok, info} = NervesGateSDK.Package.read_binary(File.read!(package))
    assert info.app == :sample_app
    assert Mix.Project.get() == project
    assert :code.get_path() == paths
    assert System.get_env() == env
    refute Code.ensure_loaded?(SampleApp)

    output =
      ExUnit.CaptureIO.capture_io(fn ->
        assert_raise RuntimeError, fn -> Workbench.Plugins.package!(plugin.path) end
      end)

    assert output =~ "Refusing to overwrite"
  end

  test "the single scenario catalogue is loaded by the workbench" do
    ids = Enum.map(Scenarios.all(), & &1.id)
    assert "sd_plugins" in ids and "sdk" in ids and "public_status" in ids
  end
end

defmodule Dev.SolutionTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir

  test "separate solutions have no platform project and generate SDK-only apps", %{tmp_dir: dir} do
    path = Path.join(dir, "a solution")
    solution = Dev.Solution.new!(path)
    assert solution.settings.platform == Dev.version()
    assert solution.settings.firmware == :local
    refute File.exists?(Path.join(path, "mix.exs"))
    app = Dev.Solution.app_new!(solution, "telemetry")
    mix = File.read!(Path.join(app, "mix.exs"))
    assert mix =~ "{:nerves_gate_sdk, \"~> 0.1.0\"}"
    refute mix =~ ":nerves_gate_sim"
    assert File.exists?(Path.join(app, ".formatter.exs"))
    assert File.exists?(Path.join(app, ".gitignore"))

    for file <- Path.wildcard(Path.join(path, "**/*.{ex,exs}"), match_dot: true) do
      contents = File.read!(file)
      assert contents == IO.iodata_to_binary(Code.format_string!(contents)) <> "\n", file
    end

    assert_raise ArgumentError, ~r/overwrite/, fn -> Dev.Solution.new!(path) end

    assert_raise ArgumentError, ~r/overwrite/, fn ->
      Dev.Solution.app_new!(solution, "telemetry")
    end

    for name <- [
          "../escape",
          "Uppercase",
          "bad-name",
          "nerves_gate_dev",
          "nerves_gate_sdk",
          "dev"
        ] do
      assert_raise ArgumentError, fn -> Dev.Solution.app_new!(solution, name) end
    end

    assert_raise ArgumentError, fn -> Dev.Solution.select!(solution, "../escape") end
  end

  test "local SDK app builds and packages outside this VM without loading app code", %{
    tmp_dir: dir
  } do
    solution = Dev.Solution.new!(Path.join(dir, "local"), true)
    app = Dev.Solution.app_new!(solution, "sample_app")

    assert File.read!(Path.join(app, "mix.exs")) =~
             "path: #{inspect(Path.join(Dev.root(), "sdk"))}"

    project = Mix.Project.get()
    paths = :code.get_path()
    env = System.get_env()
    assert :ok = Dev.Solution.test!(solution)
    package = Dev.Solution.package!(solution)
    assert {:ok, info} = NervesGateSDK.Package.read_binary(File.read!(package))
    assert info.app == :sample_app
    assert Mix.Project.get() == project
    assert :code.get_path() == paths
    assert System.get_env() == env
    refute Code.ensure_loaded?(SampleApp)
    assert_raise RuntimeError, fn -> Dev.Solution.package!(solution) end
    Dev.Solution.app_new!(solution, "another_app")
    assert_raise ArgumentError, ~r/Select an app/, fn -> Dev.Solution.select!(solution, nil) end

    assert_raise ArgumentError, ~r/Unknown app/, fn ->
      Dev.Solution.select!(solution, "absent")
    end
  end

  test "solution platform mismatch warns and simulator paths remain solution-relative", %{
    tmp_dir: dir
  } do
    solution = Dev.Solution.new!(Path.join(dir, "custom"))
    settings = %{solution.settings | platform: "0.0.0", firmware: "images/custom.fw"}
    File.write!(Path.join(solution.path, "nerves_gate.exs"), inspect(settings))
    solution = Dev.Solution.load!(solution.path)
    assert solution.warning =~ "checkout is #{Dev.version()}"
    config = NervesGateSim.Simulator.config(Dev.Solution.simulator_config!(solution, dir), dir)
    assert config.firmware == Path.join(solution.path, "images/custom.fw")
    assert config.firmware_project == nil
  end

  test "scenario catalog stays owned by the simulator and loaded by the platform" do
    ids = Enum.map(NervesGateSim.QemuTests.scenarios(), & &1.id)
    assert "apps" in ids and "sdk" in ids and "public_status" in ids
  end
end

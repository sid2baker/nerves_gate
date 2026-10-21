defmodule NervesGateNew.GeneratorTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "nerves_gate_new_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "generates a workspace with one independent SDK app and short commands", %{root: root} do
    path = Path.join(root, "my_workspace")
    Mix.Tasks.NervesGate.New.run([path])
    workspace = File.read!(Path.join(path, "mix.exs"))

    for command <- ["sim:", "\"app.new\":", "\"app.install\":", "\"app.package\":", "test:"] do
      assert workspace =~ command
    end

    assert workspace =~ "{:nerves_gate_sim, \"~> 0.1.0\""
    assert workspace =~ ":nerves_gate_new"
    refute workspace =~ "apps_path:"

    app = Path.join(path, "apps/my_app")
    mix = File.read!(Path.join(app, "mix.exs"))
    assert mix =~ "{:nerves_gate_sdk, \"~> 0.1.0\"}"
    refute mix =~ ":nerves_gate_sim"
    assert mix =~ "nerves_gate_sdk_requirement: \"~> 0.1.0\""
    assert mix =~ "nerves_gate_health_check: {MyApp, :health_check, []}"
    assert File.exists?(Path.join(app, "lib/my_app/application.ex"))
    assert File.exists?(Path.join(app, "test/my_app_test.exs"))
    assert File.exists?(Path.join(path, "config/simulator.exs"))
    refute File.exists?(Path.join(path, "mix.lock"))

    readme = File.read!(Path.join(path, "README.md"))
    assert readme =~ "mix sim"
    assert readme =~ "mix app.install my_app"
    assert readme =~ "mix app.package telemetry"
    assert readme =~ "Application storage → Use this card"

    for file <- Path.wildcard(Path.join(path, "**/*.{ex,exs}"), match_dot: true) do
      assert {:ok, _} = file |> File.read!() |> Code.string_to_quoted()
    end

    assert_raise Mix.Error, ~r/Refusing to overwrite/, fn ->
      Mix.Tasks.NervesGate.New.run([path])
    end
  end

  test "additional apps have independent metadata and cannot overwrite an app", %{root: root} do
    apps = Path.join(root, "apps")
    NervesGateNew.app(apps, "telemetry_app")

    assert File.read!(Path.join(apps, "telemetry_app/mix.exs")) =~
             "mod: {TelemetryApp.Application, []}"

    assert_raise Mix.Error, ~r/Refusing to overwrite/, fn ->
      NervesGateNew.app(apps, "telemetry_app")
    end

    for name <- ["bad-name", "Uppercase", "../escape", "nerves_gate_sdk"] do
      assert_raise Mix.Error, fn -> NervesGateNew.app(apps, name) end
    end
  end

  test "local workspaces and additional apps use checkout sources", %{root: root} do
    source = Path.expand("../..", __DIR__)
    path = Path.join(root, "local_workspace")
    Mix.Tasks.NervesGate.New.run([path, "--local", source])
    workspace = File.read!(Path.join(path, "mix.exs"))
    assert workspace =~ "nerves_gate_source: #{inspect(source)}"
    assert workspace =~ "System.put_env(\"NERVES_GATE_LOCAL_DEPS\", \"1\")"

    for project <- ["new", "sim"] do
      assert workspace =~ "path: #{inspect(Path.join(source, project))}"
    end

    sdk = "path: #{inspect(Path.join(source, "sdk"))}"
    assert File.read!(Path.join(path, "apps/my_app/mix.exs")) =~ sdk
    NervesGateNew.app(Path.join(path, "apps"), "example_app", source)
    assert File.read!(Path.join(path, "apps/example_app/mix.exs")) =~ sdk

    for file <- Path.wildcard(Path.join(path, "**/*.{ex,exs}"), match_dot: true) do
      assert {:ok, _} = file |> File.read!() |> Code.string_to_quoted()
    end
  end

  test "rejects invalid workspace names", %{root: root} do
    for name <- ["bad-name", "Uppercase"] do
      assert_raise Mix.Error, fn -> Mix.Tasks.NervesGate.New.run([Path.join(root, name)]) end
      refute File.exists?(Path.join(root, name))
    end
  end
end

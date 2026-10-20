defmodule NervesGateNew.GeneratorTest do
  use ExUnit.Case, async: false

  setup do
    root = Path.join(System.tmp_dir!(), "nerves_gate_new_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  test "generates a standalone application with SDK, simulator and packaging metadata", %{
    root: root
  } do
    path = Path.join(root, "my_app")
    Mix.Tasks.NervesGate.New.run([path])
    mix = File.read!(Path.join(path, "mix.exs"))
    assert mix =~ "{:nerves_gate_sdk, \"~> 1.0\"}"
    assert mix =~ "{:nerves_gate_sim, \"~> 1.0\", only: :dev, runtime: false}"
    assert mix =~ "nerves_gate_sdk_requirement: \"~> 1.0\""
    assert mix =~ "nerves_gate_health_check: {MyApp, :health_check, []}"

    for file <- Path.wildcard(Path.join(path, "**/*.{ex,exs}"), match_dot: true) do
      assert {:ok, _} = file |> File.read!() |> Code.string_to_quoted()
    end

    assert File.exists?(Path.join(path, "lib/my_app/application.ex"))
    assert File.exists?(Path.join(path, "test/my_app_test.exs"))
    assert File.exists?(Path.join(path, ".gitignore"))
    refute File.exists?(Path.join(path, "mix.lock"))

    assert_raise Mix.Error, ~r/Refusing to overwrite/, fn ->
      Mix.Tasks.NervesGate.New.run([path])
    end
  end

  test "rejects invalid and platform application names", %{root: root} do
    for name <- ["bad-name", "Uppercase", "nerves_gate_sdk"] do
      assert_raise Mix.Error, fn -> Mix.Tasks.NervesGate.New.run([Path.join(root, name)]) end
      refute File.exists?(Path.join(root, name))
    end
  end
end

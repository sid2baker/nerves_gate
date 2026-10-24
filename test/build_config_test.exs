defmodule Workbench.BuildConfigTest do
  use ExUnit.Case, async: false

  test "root configuration selects host even when the caller selected a device target" do
    previous = Mix.target()
    inherited = System.get_env("MIX_TARGET")

    try do
      for target <- [:ec100, :x86_64] do
        Mix.target(target)
        assert Workbench.MixProject.project()[:app] == :nerves_gate_workbench
        assert Mix.target() == :host
        assert System.get_env("MIX_TARGET") == inherited
      end
    after
      Mix.target(previous)
    end
  end

  test "firmware command rejects unsupported targets and environments before building" do
    firmware = Workbench.MixProject.project()[:aliases][:firmware]

    for args <- [
          ["unknown"],
          ["x86_64", "--env", "prod"],
          ["ec100", "--env", "test"],
          ["ec100", "extra"]
        ] do
      assert_raise Mix.Error, ~r/Usage: mix firmware/, fn -> firmware.(args) end
    end
  end

  test "only host development enables the workbench code reload listener" do
    previous = Mix.env()

    try do
      for env <- [:dev, :test, :docs, :prod] do
        Mix.env(env)

        assert Workbench.MixProject.project()[:listeners] ==
                 if(env == :dev, do: [Phoenix.CodeReloader], else: [])
      end
    after
      Mix.env(previous)
    end
  end
end

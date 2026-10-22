defmodule Dev.BuildConfigTest do
  use ExUnit.Case, async: false

  test "root configuration selects host even when the caller selected a device target" do
    previous = Mix.target()
    inherited = System.get_env("MIX_TARGET")

    try do
      for target <- [:ec100, :x86_64] do
        Mix.target(target)
        assert Dev.MixProject.project()[:app] == :nerves_gate_dev
        assert Mix.target() == :host
        assert System.get_env("MIX_TARGET") == inherited
      end
    after
      Mix.target(previous)
    end
  end

  test "only host development enables the workbench code reload listener" do
    previous = Mix.env()

    try do
      for env <- [:dev, :test, :docs, :prod] do
        Mix.env(env)

        assert Dev.MixProject.project()[:listeners] ==
                 if(env == :dev, do: [Phoenix.CodeReloader], else: [])
      end
    after
      Mix.env(previous)
    end
  end
end

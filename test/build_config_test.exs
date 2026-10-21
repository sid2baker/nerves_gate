defmodule Dev.BuildConfigTest do
  use ExUnit.Case, async: false

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

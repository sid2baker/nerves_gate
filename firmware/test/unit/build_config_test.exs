defmodule NervesGate.BuildConfigTest do
  use ExUnit.Case, async: false

  test "code reload listeners are restricted to host development" do
    project = Mix.Project.get()
    previous_env = Mix.env()
    previous_target = Mix.target()

    try do
      for {target, env} <- [host: :dev, host: :test, host: :docs, x86_64: :dev, ec100: :prod] do
        Mix.env(env)
        Mix.target(target)
        listeners = project.project()[:listeners]

        if {target, env} == {:host, :dev},
          do: assert(listeners == [Phoenix.CodeReloader]),
          else: assert(listeners == [])
      end
    after
      Mix.env(previous_env)
      Mix.target(previous_target)
    end
  end
end

defmodule NervesGate.BuildConfigTest do
  use ExUnit.Case, async: false

  test "only EC100 selects the ECM modem and both targets protect input before networking" do
    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!("config/config.exs", env: :dev, target: target)

      assert config[:nerves_runtime][:init_module] == NervesGate.Recovery.DataInit
      assert config[:nerves][:application_sort] == [init: [:nerves_runtime]]

      if target == :ec100 do
        assert config[:nerves_gate][:cellular] == %{
                 interface: "wwan0",
                 config: %{type: VintageNetECM, vintage_net_ecm: %{at_tty: "ttyUSB2"}}
               }
      else
        assert config[:nerves_gate][:cellular] == nil
      end
    end
  end

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

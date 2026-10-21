defmodule NervesGateTools.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_gate_tools,
      version: "0.0.0",
      elixir: "~> 1.20",
      deps: [],
      aliases: [ci: ["compile --warnings-as-errors", "format --check-formatted", "test"]]
    ]
  end

  def cli, do: [preferred_envs: [ci: :test]]
  def application, do: [extra_applications: [:crypto]]
end

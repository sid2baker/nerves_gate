defmodule NervesGateSim.MixProject do
  use Mix.Project

  @external_resource Path.expand("../VERSION", __DIR__)
  @version @external_resource |> File.read!() |> String.trim()

  def project do
    [
      app: :nerves_gate_sim,
      version: @version,
      elixir: "~> 1.20",
      description: "Owned QEMU devices, virtual networking and scenario admission",
      aliases: [ci: ["compile --warnings-as-errors", "format --check-formatted", "test"]],
      deps: [
        {:nerves_gate_sdk, path: "../sdk"},
        {:nerves_gate, path: "../firmware", runtime: false},
        {:req, "~> 0.7"},
        {:floki, "~> 0.38"}
      ]
    ]
  end

  def cli, do: [preferred_envs: [ci: :test]]
  def application, do: [extra_applications: [:logger]]
end

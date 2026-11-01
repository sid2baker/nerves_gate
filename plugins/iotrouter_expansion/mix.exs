defmodule IotrouterExpansion.MixProject do
  use Mix.Project

  def project do
    [
      app: :iotrouter_expansion,
      version: "0.1.1-dev.1",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:nerves_gate_sdk, "~> 0.2.0-dev.8", path: "../../sdk"},
        {:circuits_uart, "== 1.7.0"},
        {:circuits_gpio, "== 2.3.1"},
        {:phoenix_live_view, "== 1.2.13"}
      ]
    ]
  end

  def cli, do: [preferred_envs: ["nerves_gate.package": :prod]]

  def application do
    [
      extra_applications: [:logger],
      mod: {IotrouterExpansion.Application, []},
      env: [
        nerves_gate_sdk_requirement: "~> 0.2.0-dev.8",
        nerves_gate_health_check: {IotrouterExpansion, :health_check, []},
        nerves_gate_ui: IotrouterExpansion.UI,
        nerves_gate_hardware: [:iotrouter_expansion]
      ]
    ]
  end
end

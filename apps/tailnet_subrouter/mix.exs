defmodule TailnetSubrouter.MixProject do
  use Mix.Project

  def project do
    [
      app: :tailnet_subrouter,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [
        {:nerves_gate_sdk, "~> 0.2.0-dev", path: "../../sdk"},
        {:phoenix_live_view, "== 1.2.13"}
      ]
    ]
  end

  def cli, do: [preferred_envs: ["nerves_gate.package": :prod]]

  def application do
    [
      extra_applications: [:logger],
      mod: {TailnetSubrouter.Application, []},
      env: [
        nerves_gate_sdk_requirement: "~> 0.2.0-dev",
        nerves_gate_health_check: {TailnetSubrouter, :health_check, []},
        nerves_gate_ui: TailnetSubrouter.UI
      ]
    ]
  end
end

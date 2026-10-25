defmodule TailnetSubrouter.MixProject do
  use Mix.Project

  def project do
    [
      app: :tailnet_subrouter,
      version: "1.0.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: [{:nerves_gate_sdk, "~> 0.1.0", path: "../../sdk"}]
    ]
  end

  def cli, do: [preferred_envs: ["nerves_gate.package": :prod]]

  def application do
    [
      extra_applications: [:logger],
      mod: {TailnetSubrouter.Application, []},
      env: [
        nerves_gate_sdk_requirement: "~> 0.1.0",
        nerves_gate_health_check: {TailnetSubrouter, :health_check, []}
      ]
    ]
  end
end

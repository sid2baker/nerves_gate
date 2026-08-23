defmodule NervesGateQEMU.MixProject do
  use Mix.Project

  def project do
    [
      app: :nerves_gate_qemu,
      version: "0.1.0",
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

  def cli do
    [preferred_envs: [ci: :test]]
  end

  def application do
    [
      mod: {NervesGateQEMU.Application, []},
      extra_applications: [:crypto, :inets, :logger, :runtime_tools, :ssl]
    ]
  end

  defp deps do
    [
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.2"},
      {:tailwind, "~> 0.5.1", runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases do
    [
      "assets.build": ["tailwind default --minify"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict --config-file .credo.exs"
      ]
    ]
  end
end

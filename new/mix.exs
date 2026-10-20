defmodule NervesGateNew.MixProject do
  use Mix.Project

  @version __DIR__ |> Path.join("VERSION") |> File.read!() |> String.trim()

  def project do
    [
      app: :nerves_gate_new,
      version: @version,
      elixir: "~> 1.20",
      description: "Generate portable Nerves Gate applications",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/sid2baker/nerves_gate"},
        files: ~w(lib priv mix.exs VERSION README.md CHANGELOG.md LICENSE)
      ],
      aliases: [ci: ["compile --warnings-as-errors", "format --check-formatted", "test"]],
      deps: []
    ]
  end

  def cli, do: [preferred_envs: [ci: :test]]

  def application, do: [extra_applications: [:eex]]
end

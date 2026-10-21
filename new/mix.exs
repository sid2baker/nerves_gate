defmodule NervesGateNew.MixProject do
  use Mix.Project

  @external_resource Path.join(__DIR__, "VERSION")
  @version __DIR__ |> Path.join("VERSION") |> File.read!() |> String.trim()

  def project do
    [
      app: :nerves_gate_new,
      version: @version,
      elixir: "~> 1.20",
      description: "Generate Nerves Gate app-development workspaces",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/sid2baker/nerves_gate"},
        files: ~w(lib priv mix.exs VERSION README.md CHANGELOG.md LICENSE)
      ],
      aliases: [ci: ["compile --warnings-as-errors", "format --check-formatted", "test"]],
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      deps: [
        {:ex_doc, "~> 0.40", only: :docs, runtime: false},
        {:req, "~> 0.7", runtime: false}
      ]
    ]
  end

  def cli, do: [preferred_envs: [ci: :test]]

  def application, do: [extra_applications: [:eex]]
end

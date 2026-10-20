defmodule NervesGateSDK.MixProject do
  use Mix.Project

  @version __DIR__ |> Path.join("VERSION") |> File.read!() |> String.trim()

  def project do
    [
      app: :nerves_gate_sdk,
      version: @version,
      elixir: "~> 1.20",
      description: "Portable application API for Nerves Gate",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/sid2baker/nerves_gate"},
        files: ~w(lib mix.exs VERSION README.md CHANGELOG.md LICENSE)
      ],
      aliases: [ci: ["compile --warnings-as-errors", "format --check-formatted", "test"]],
      deps: []
    ]
  end

  def cli, do: [preferred_envs: [ci: :test]]

  def application, do: []
end

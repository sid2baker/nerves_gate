defmodule NervesGateSim.MixProject do
  use Mix.Project

  @external_resource Path.join(__DIR__, "VERSION")
  @version __DIR__ |> Path.join("VERSION") |> File.read!() |> String.trim()

  def project do
    [
      app: :nerves_gate_sim,
      version: @version,
      elixir: "~> 1.20",
      description: "Disposable QEMU devices and development tools for Nerves Gate",
      elixirc_paths: if(File.dir?("scenarios"), do: ["lib", "scenarios"], else: ["lib"]),
      listeners: [Phoenix.CodeReloader],
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/sid2baker/nerves_gate"},
        files: ~w(lib priv config mix.exs VERSION README.md CHANGELOG.md LICENSE)
      ],
      aliases: [ci: ["compile --warnings-as-errors", "format --check-formatted", "test"]],
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      deps: [
        {:ex_doc, "~> 0.40", only: :docs, runtime: false},
        local_dependency(:nerves_gate_sdk, "~> 0.1.0", "../sdk", []),
        # Compiled for the workstation UI and scenarios; started only by the session.
        local_dependency(:nerves_gate, "~> 0.1", "../firmware", runtime: false),
        {:req, "~> 0.7"},
        {:floki, "~> 0.38"},
        # Code reloading for the gateway UI and simulator site (optional in firmware).
        {:volt, "~> 0.23.0", only: :dev},
        {:phoenix_live_reload, "~> 1.5", only: :dev},
        {:tidewave, "~> 0.9", only: :dev}
      ]
    ]
  end

  # This package provides tools, not an automatically started hardware backend.
  # Only an explicit simulator command may launch the owned QEMU session.
  def cli, do: [preferred_envs: [ci: :test]]

  def application, do: [extra_applications: [:logger]]

  defp local_dependency(app, requirement, path, options) do
    options =
      if System.get_env("NERVES_GATE_LOCAL_DEPS") == "1",
        do: Keyword.put(options, :path, path),
        else: options

    {app, requirement, options}
  end
end

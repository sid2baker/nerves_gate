defmodule NervesGateSDK.MixProject do
  use Mix.Project

  @external_resource Path.join(__DIR__, "VERSION")
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
      aliases: [
        check: ["compile --warnings-as-errors", "format --check-formatted", "test"],
        ci: ["check"],
        compile: [&drop_stale_app/1, "compile"]
      ],
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      deps: [{:ex_doc, "~> 0.40", only: :docs, runtime: false}]
    ]
  end

  def cli, do: [preferred_envs: [ci: :test, check: :test]]

  def application, do: []

  # Mix regenerates the .app file when mix.exs or config changes, not VERSION.
  defp drop_stale_app(_args) do
    app = Path.join(Mix.Project.compile_path(), "nerves_gate_sdk.app")

    with {:ok, [{:application, _, properties}]} <- :file.consult(app),
         false <- to_string(properties[:vsn]) == @version,
         do: File.rm!(app)
  end
end

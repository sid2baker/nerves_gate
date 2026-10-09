defmodule NervesGate.MixProject do
  use Mix.Project

  @targets [:ec100, :x86_64]

  def project do
    [
      app: :nerves_gate,
      version: "0.1.0",
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.17"],
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      deps: deps(),
      lockfile: if(Mix.target() == :host, do: "mix.lock", else: "mix.#{Mix.target()}.lock"),
      releases: [nerves_gate: [steps: [&Nerves.init_release/1, :assemble]]]
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {NervesGate.Application, []}]
  end

  def cli, do: [preferred_targets: [run: :host, test: :host]]

  defp deps do
    [
      {:nerves, "~> 2.0.0-pre.3", runtime: false},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.2"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:tailscale,
       github: "sid2baker/tailscale_ex", ref: "374d17ab1b1ef7535b45d4113b104cbaadabf2e2"},
      {:nerves_runtime, "~> 0.13", targets: @targets},
      {:ring_logger, "~> 0.11", targets: @targets},
      {:nerves_ssh, "~> 1.3", targets: @targets},
      {:nerves_time, "~> 0.4", targets: @targets},
      {:vintage_net, "~> 0.13", runtime: Mix.target() != :host},
      {:vintage_net_bridge, "~> 0.10.3", runtime: Mix.target() != :host},
      {:vintage_net_ethernet, "~> 0.11", runtime: Mix.target() != :host},
      {:vintage_net_direct, "~> 0.10", targets: @targets},
      {:nerves_system_ec100,
       github: "sid2baker/nerves_system_ec100",
       ref: "9e75902dd6bf33826e1df5c86ba4a84c13511fbf",
       runtime: false,
       targets: :ec100},
      {:nerves_system_x86_64,
       github: "nerves-project/nerves_system_x86_64",
       ref: "5d755dba94fff478eac2bfd90ba91d2e0025d4eb",
       runtime: false,
       targets: :x86_64}
    ]
    |> Enum.filter(fn
      {_name, _source, opts} ->
        Mix.target() in List.wrap(Keyword.get(opts, :targets, Mix.target()))

      {_name, opts} when is_list(opts) ->
        Mix.target() in List.wrap(Keyword.get(opts, :targets, Mix.target()))

      {_name, _source} ->
        true
    end)
  end
end

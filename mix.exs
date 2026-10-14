# Select host tooling before Nerves reads the project, even after firmware builds.
case List.first(System.argv()) do
  command when command in ["dev.ec100", "dev.qemu"] ->
    Mix.env(:dev)
    Mix.target(:host)

  command when command in ["test", "test.qemu", "qemu.test", "ci"] ->
    Mix.env(:test)
    Mix.target(:host)

  _ ->
    :ok
end

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
      listeners: [Phoenix.CodeReloader],
      elixirc_paths: elixirc_paths(),
      deps: deps(),
      releases: [
        nerves_gate: [
          include_erts: &Nerves.erts/0,
          applications: if(Mix.target() == :ec100, do: [nerves_runtime: :transient], else: []),
          steps: [&Nerves.init_release/1, :assemble]
        ]
      ],
      dialyzer: [
        plt_add_apps: [
          :mix,
          :muontrap,
          :ex_unit,
          :tailscale,
          :vintage_net,
          :vintage_net_bridge,
          :vintage_net_ethernet
        ]
      ],
      aliases: [
        test: ["qemu.test"],
        "test.qemu": ["qemu.test"],
        ci: [
          "compile --warnings-as-errors",
          "format --check-formatted",
          "credo --strict",
          "dialyzer",
          "ex_dna --max-clones 0",
          "reach.check --arch --smells",
          "qemu.test --ci"
        ]
      ]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto], mod: {NervesGate.Application, []}]

  def cli do
    [
      preferred_targets: [
        run: :host,
        test: :host,
        ci: :host,
        "dev.ec100": :host,
        "dev.qemu": :host,
        "qemu.test": :host
      ],
      preferred_envs: [ci: :test, "dev.ec100": :dev, "dev.qemu": :dev, "qemu.test": :test]
    ]
  end

  defp elixirc_paths do
    if Mix.target() == :host and Mix.env() in [:dev, :test],
      do: ["lib", "dev", "test/support", "test/scenarios"],
      else: ["lib"]
  end

  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test]},
      {:nerves, "~> 2.0.0-pre.4", runtime: false},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_reload, "~> 1.5", only: :dev, targets: :host},
      {:tidewave, "~> 0.9", only: :dev, targets: :host},
      # PR #4441: lifecycle-managed LiveView/LiveComponent PubSub subscriptions.
      {:phoenix_live_view, github: "phoenixframework/phoenix_live_view", branch: "main"},
      {:phoenix_pubsub, "~> 2.4"},
      {:alarmist, "~> 0.4.2"},
      {:property_table, "~> 0.3.4"},
      {:circuits_uart, "~> 1.6"},
      {:input_event, "~> 1.4"},
      # Host tooling must never start the workstation VPN.
      {:tailscale,
       github: "sid2baker/tailscale_ex",
       ref: "ad64feb5d999a07c1a4ded4a04c99adb374a7b07",
       runtime: Mix.target() != :host},
      {:nerves_runtime, "~> 0.13", targets: @targets},
      {:nerves_motd, "~> 0.1", targets: @targets},
      {:ring_logger, "~> 0.11", targets: @targets},
      {:nerves_ssh, "~> 1.3", targets: @targets},
      {:nerves_time, "~> 0.4", targets: @targets},
      {:vintage_net, "~> 0.13", runtime: Mix.target() != :host},
      {:vintage_net_bridge, "~> 0.10.3", runtime: Mix.target() != :host},
      {:vintage_net_ethernet, "~> 0.11", runtime: Mix.target() != :host},
      {:vintage_net_direct, "~> 0.10", targets: @targets},
      {:nerves_system_ec100,
       path: "/home/n0gg1n/Development/Work/ism/dev/nerves_system_ec100",
       runtime: false,
       targets: :ec100},
      {:nerves_system_x86_64,
       path: "systems/nerves_system_x86_64", runtime: false, targets: :x86_64}
    ]
  end
end

# Select host tooling before Nerves reads the project, even after firmware builds.
case List.first(System.argv()) do
  command when command in ["setup", "dev.ui", "dev", "dev.status", "dev.stop", "assets.build"] ->
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
          applications: if(Mix.target() in @targets, do: [nerves_runtime: :transient], else: []),
          steps: [&Nerves.init_release/1, &gateway_restart_policy/1, :assemble]
        ]
      ],
      dialyzer: [
        plt_add_apps: [
          :mix,
          :nerves,
          :nerves_runtime,
          :muontrap,
          :one_dhcpd,
          :ssh,
          :ex_unit,
          :tailscaled_ex,
          :vintage_net,
          :vintage_net_bridge,
          :vintage_net_ethernet
        ]
      ],
      aliases: [
        setup: &setup/1,
        "assets.build": ["volt.build --tailwind"],
        test: ["qemu.test"],
        "test.qemu": ["qemu.test"],
        ci: [
          "compile --warnings-as-errors",
          "format --check-formatted",
          "volt.js.check",
          "credo --strict",
          "dialyzer",
          "ex_dna --max-clones 0",
          "reach.check --arch --smells",
          "qemu.test --ci"
        ]
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :ssh], mod: {NervesGate.Application, []}]

  def cli do
    [
      preferred_targets: [
        run: :host,
        setup: :host,
        test: :host,
        ci: :host,
        "dev.ui": :host,
        "dev.status": :host,
        "dev.stop": :host,
        dev: :host,
        "qemu.test": :host,
        "assets.build": :host
      ],
      preferred_envs: [
        setup: :dev,
        ci: :test,
        "dev.ui": :dev,
        "dev.status": :dev,
        "dev.stop": :dev,
        dev: :dev,
        "qemu.test": :test,
        "assets.build": :dev
      ]
    ]
  end

  # Setting the app mode in applications: also changes its dependencies' modes.
  # Change only the gateway's boot entry; Nerves preserves explicit transient modes.
  defp gateway_restart_policy(release) do
    if Mix.target() in @targets do
      scripts =
        Map.update!(release.boot_scripts, :start, &Keyword.replace!(&1, :nerves_gate, :transient))

      %{release | boot_scripts: scripts}
    else
      release
    end
  end

  # Setup must be available before dependencies or ordinary dev tasks can compile.
  defp setup(args) do
    Code.require_file("dev/setup.exs", __DIR__)
    Mix.Task.run("setup.qemu", args)
  end

  defp elixirc_paths do
    if Mix.target() == :host,
      do: ["lib", "dev", "test/support", "test/scenarios"],
      else: ["lib"]
  end

  defp deps do
    [
      {:volt, "~> 0.23.0", only: [:dev, :test], targets: :host},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:nerves, "~> 2.0.0-pre.4", runtime: false},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_reload, "~> 1.5", only: :dev, targets: :host},
      {:tidewave, "~> 0.9", only: :dev, targets: :host},
      {:req, "~> 0.7", only: [:dev, :test], targets: :host},
      # PR #4441: lifecycle-managed LiveView/LiveComponent PubSub subscriptions.
      {:phoenix_live_view, github: "phoenixframework/phoenix_live_view", branch: "main"},
      {:phoenix_pubsub, "~> 2.4"},
      {:alarmist, "~> 0.4.2"},
      {:property_table, "~> 0.3.4"},
      {:circuits_uart, "~> 1.6"},
      {:input_event, "~> 1.4"},
      {:yaopcua, github: "tallakt/yaopcua"},
      {:yamodbus, github: "tallakt/yamodbus"},
      {:s7, github: "sid2baker/s7"},
      {:ethercat, github: "sid2baker/ethercat"},
      # Host tooling must never start the workstation VPN.
      {:tailscaled_ex, "~> 0.3.0", runtime: Mix.target() != :host},
      # Compiled on the host like VintageNet, but started only by firmware.
      {:nerves_runtime, "~> 0.13", runtime: Mix.target() != :host},
      {:nerves_motd, "~> 0.1", targets: @targets},
      {:ring_logger, "~> 0.11", targets: @targets},
      {:nerves_ssh, "~> 1.3", targets: @targets},
      {:nerves_time, "~> 0.4", targets: @targets},
      {:vintage_net, "~> 0.13", runtime: Mix.target() != :host},
      {:vintage_net_bridge, "~> 0.10.3", runtime: Mix.target() != :host},
      {:vintage_net_ethernet, "~> 0.11", runtime: Mix.target() != :host},
      {:vintage_net_direct, "~> 0.10", runtime: Mix.target() != :host},
      {:nerves_system_ec100,
       github: "sid2baker/nerves_system_ec100", tag: "v0.2.0", runtime: false, targets: :ec100},
      {:nerves_system_ec100_qemu,
       path: "systems/nerves_system_ec100_qemu", runtime: false, targets: :x86_64}
    ]
  end
end

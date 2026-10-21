defmodule NervesGate.MixProject do
  use Mix.Project
  @targets [:ec100, :x86_64]
  @external_resource Path.join(__DIR__, "VERSION")
  @version __DIR__ |> Path.join("VERSION") |> File.read!() |> String.trim()

  def project do
    [
      app: :nerves_gate,
      version: @version,
      description: "Nerves Gate device firmware and application runtime",
      package: [
        licenses: ["Apache-2.0"],
        links: %{"GitHub" => "https://github.com/sid2baker/nerves_gate"},
        files:
          ~w(lib config priv rel rootfs_overlay mix.exs VERSION README.md CHANGELOG.md LICENSE),
        exclude_patterns: [~r{^rootfs_overlay/[^/]+/usr/sbin/tailscaled$}]
      ],
      docs: [main: "readme", extras: ["README.md", "CHANGELOG.md"]],
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.17"],
      start_permanent: Mix.env() == :prod,
      listeners: [Phoenix.CodeReloader],
      elixirc_paths: ["lib"],
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
        "assets.build": ["volt.build --tailwind"],
        "tailscaled.install": &tailscaled_install/1,
        ci: [
          "compile --warnings-as-errors",
          "format --check-formatted",
          "volt.js.check",
          "credo --strict",
          "dialyzer",
          "ex_dna --max-clones 0",
          "reach.check --arch --smells"
        ]
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :ssh], mod: {NervesGate.Application, []}]

  def cli do
    [
      preferred_targets: [ci: :host, "assets.build": :host],
      preferred_envs: [ci: :test, "assets.build": :dev]
    ]
  end

  # Runs without compiling the project or its dependencies.
  defp tailscaled_install([]) do
    Code.require_file("dev/tailscaled.ex", __DIR__)
    NervesGate.Dev.Tailscaled.install()
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

  defp local_dependency(app, requirement, path, options) do
    options =
      if System.get_env("NERVES_GATE_LOCAL_DEPS") == "1",
        do: Keyword.put(options, :path, path),
        else: options

    {app, requirement, options}
  end

  defp system_dependency(app, version, target) do
    source = "systems/#{app}"

    tag =
      app |> Atom.to_string() |> String.replace_prefix("nerves_", "") |> String.replace("_", "-")

    options =
      if System.get_env("NERVES_GATE_LOCAL_DEPS") == "1" do
        [path: "../#{source}"]
      else
        [github: "sid2baker/nerves_gate", tag: "#{tag}/v#{version}", subdir: source]
      end

    {app, version, options ++ [runtime: false, targets: target]}
  end

  defp deps do
    [
      {:ex_doc, "~> 0.40", only: :docs, runtime: false},
      # Optional host tools: the simulator declares them to serve this UI with
      # code reloading; Mix then compiles them before this application.
      {:volt, "~> 0.23.0", optional: true, targets: :host},
      {:phoenix_live_reload, "~> 1.5", optional: true, targets: :host},
      {:tidewave, "~> 0.9", optional: true, targets: :host},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:nerves, "~> 2.0.0-pre.4", runtime: false},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2.13"},
      {:phoenix_pubsub, "~> 2.4"},
      {:alarmist, "~> 0.4.2"},
      {:property_table, "~> 0.3.4"},
      {:circuits_uart, "~> 1.6"},
      {:input_event, "~> 1.4"},
      # Host tooling must never start the workstation VPN.
      {:tailscaled_ex, "~> 0.4.0", runtime: Mix.target() != :host},
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
      local_dependency(:nerves_gate_sdk, "~> 0.1.0", "../sdk", [])
    ] ++ system_dependencies()
  end

  # Host consumers need the shared gateway UI, never a device system package.
  # Device builds still resolve their pinned system source and GitHub artifact.
  defp system_dependencies do
    case Mix.target() do
      :ec100 -> [system_dependency(:nerves_system_ec100, "0.2.1", :ec100)]
      :x86_64 -> [system_dependency(:nerves_system_ec100_qemu, "0.2.2", :x86_64)]
      :host -> []
    end
  end
end

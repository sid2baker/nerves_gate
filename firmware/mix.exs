defmodule NervesGate.MixProject do
  use Mix.Project
  @targets [:ec100, :x86_64]
  @external_resource Path.expand("../VERSION", __DIR__)
  @version @external_resource |> File.read!() |> String.trim()

  def project do
    [
      app: :nerves_gate,
      version: @version,
      description: "Nerves Gate device firmware and application runtime",
      docs: [main: "readme", extras: ["README.md"]],
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.17"],
      start_permanent: Mix.env() == :prod,
      # Device listeners can compile native deps before Nerves sets the toolchain,
      # silently putting workstation executables in an otherwise valid image.
      listeners:
        if(Mix.target() == :host and Mix.env() == :dev, do: [Phoenix.CodeReloader], else: []),
      elixirc_paths: ["lib"],
      deps: deps(),
      nerves: if(Mix.target() in @targets, do: [plan_callback: &firmware_metadata/1], else: []),
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
          :nerves_time,
          :muontrap,
          :one_dhcpd,
          :ssh,
          :ex_unit,
          :tailscaled_ex,
          :vintage_net,
          :vintage_net_bridge,
          :vintage_net_ecm,
          :vintage_net_ethernet
        ]
      ],
      aliases: [
        "assets.build": ["volt.build --tailwind"],
        check: [
          "compile --warnings-as-errors",
          "format --check-formatted",
          "test",
          "volt.js.check",
          "credo --strict",
          "ex_dna --max-clones 0",
          "reach.check --arch --smells"
        ],
        ci: ["check", "dialyzer"]
      ]
    ]
  end

  def application,
    do: [extra_applications: [:logger, :crypto, :ssh], mod: {NervesGate.Application, []}]

  def cli do
    [
      preferred_targets: [ci: :host, check: :host, "assets.build": :host],
      preferred_envs: [ci: :test, check: :test, "assets.build": :dev]
    ]
  end

  # Nerves 2 exposes extra firmware metadata through the build plan, not the
  # legacy application-env compatibility options.
  defp firmware_metadata(plan) do
    revision = Application.fetch_env!(:nerves, :firmware) |> Keyword.fetch!(:fw_vcs_identifier)
    Nerves.BuildPlan.merge_config(plan, fw_vcs_identifier: revision)
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
      # Gateway host tests and Volt share the same host-only HTML parser.
      {:floki, "~> 0.38", targets: :host},
      # Frontend tooling runs on the host, never in device firmware.
      {:volt, "~> 0.23.0", optional: true, targets: :host},
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
      {:tailscaled_ex, "~> 0.5.0", runtime: Mix.target() != :host},
      # Compiled on the host like VintageNet, but started only by firmware.
      {:nerves_runtime, "~> 0.13", runtime: Mix.target() != :host},
      {:nerves_motd, "~> 0.1", targets: @targets},
      {:ring_logger, "~> 0.11", targets: @targets},
      {:nerves_ssh, "~> 1.3", targets: @targets},
      {:mdns_lite, "~> 0.9.3", targets: @targets},
      {:nerves_time, "~> 0.4", runtime: Mix.target() != :host},
      # Teardown fix pending upstream release: https://github.com/nerves-networking/vintage_net/issues/597
      {:vintage_net, "~> 0.13",
       github: "jannikbecher/vintage_net",
       ref: "5cd3e5fc5876f17367c47f84073ce39933c3efe6",
       override: true,
       runtime: Mix.target() != :host},
      {:vintage_net_bridge, "~> 0.10.3", runtime: Mix.target() != :host},
      {:vintage_net_ethernet, "~> 0.11", runtime: Mix.target() != :host},
      {:vintage_net_ecm, "~> 0.2.1", runtime: Mix.target() != :host},
      {:vintage_net_direct, "~> 0.10", runtime: Mix.target() != :host},
      {:nerves_gate_sdk, path: "../sdk"}
    ] ++ system_dependencies()
  end

  # Host consumers need the shared gateway UI, never a device system package.
  # Device builds still resolve their pinned system source and GitHub artifact.
  defp system_dependencies do
    case Mix.target() do
      :ec100 -> [system_dependency(:nerves_system_ec100, "0.3.0", :ec100)]
      :x86_64 -> [system_dependency(:nerves_system_ec100_qemu, "0.2.2", :x86_64)]
      :host -> []
    end
  end
end

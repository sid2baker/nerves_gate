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
      releases: [
        nerves_gate: [
          include_erts: &Nerves.erts/0,
          steps: [&set_source_date_epoch/1, &Nerves.init_release/1, :assemble]
        ]
      ],
      dialyzer: [plt_add_apps: [:ex_unit]],
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {NervesGate.Application, []}]
  end

  def cli, do: [preferred_targets: [run: :host, test: :host], preferred_envs: [ci: :test]]

  defp set_source_date_epoch(release) do
    if Mix.target() in @targets do
      # Nerves 2.0.0-pre.3 validates :source_date_epoch but forwards a misspelled key
      # to fwup. Export the configured value until that upstream typo is fixed.
      System.put_env("SOURCE_DATE_EPOCH", Application.fetch_env!(:nerves, :source_date_epoch))
    end

    release
  end

  defp deps do
    [
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:vibe_kit, "~> 0.1", only: [:dev, :test]},
      {:nerves, "~> 2.0.0-pre.3", runtime: false},
      {:bandit, "~> 1.12"},
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.8"},
      # PR #4441: lifecycle-managed LiveView/LiveComponent PubSub subscriptions.
      {:phoenix_live_view, github: "phoenixframework/phoenix_live_view", branch: "main"},
      {:phoenix_pubsub, "~> 2.4"},
      # Pin the reviewed workflow API rather than following Runic's alpha main branch.
      {:runic, github: "zblanco/runic", ref: "6e6373832c00aa9ec5d19faeae945b61e2db50b1"},
      {:lazy_html, ">= 0.1.0", only: :test},
      # tailscale_ex owns its daemon; host simulation must never start the workstation VPN.
      {:tailscale,
       github: "sid2baker/tailscale_ex",
       ref: "3a859e7dc30c14b993c43b7b9b93c9d2f38c99a6",
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
      {:nerves_system_x86_64, path: "systems/x86_64", runtime: false, targets: :x86_64}
    ]
  end

  defp aliases() do
    [
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells"
      ]
    ]
  end
end

defmodule NervesGate.MixProject do
  use Mix.Project

  @app :nerves_gate
  @version System.get_env("NERVES_GATE_VERSION", "0.1.0")
  @all_targets [:x86_64]

  def project do
    [
      app: @app,
      version: @version,
      elixir: "~> 1.20",
      archives: [nerves_bootstrap: "~> 1.17"],
      compilers: [:finitomata | Mix.compilers()],
      listeners: listeners(Mix.target(), Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [{@app, release()}],
      dialyzer: [plt_add_apps: [:ex_unit, :mix]],
      docs: [
        main: "readme",
        extras: ["README.md", "docs/command-event-state-implementation-plan.md"],
        before_closing_body_tag: &before_closing_body_tag/1
      ],
      aliases: aliases(),
      test_ignore_filters: [&String.starts_with?(&1, "test/support/")]
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:crypto, :inets, :logger, :runtime_tools, :sasl, :ssl],
      mod: {NervesGate.Application, []}
    ]
  end

  def cli do
    [preferred_targets: [run: :host, test: :host], preferred_envs: [ci: :test]]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, "~> 0.40.3", only: :dev, runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:reach, "~> 2.0", only: [:dev, :test], runtime: false},
      {:ex_dna, "~> 1.0", only: [:dev, :test], runtime: false},
      {:tailwind, "~> 0.5.1", runtime: false},
      {:dialyxir, "~> 1.0", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.0", only: [:dev, :test], runtime: false},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:vibe_kit, "~> 0.1"},

      # Runtime dependencies
      {:alarmist, "~> 0.4.2"},
      {:bandit, "~> 1.12"},
      {:finitomata, "~> 0.43.0"},
      {:jason, "~> 1.4"},
      {:muontrap, "~> 1.0"},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.2"},
      {:phoenix_pubsub, "~> 2.2"},
      {:tailscale, github: "sid2baker/tailscale_ex"},

      # Dependencies for all targets
      {:nerves, "~> 1.13", runtime: false},
      {:shoehorn, "~> 0.9.1"},
      {:ring_logger, "~> 0.11.0"},
      {:toolshed, "~> 0.5.0"},

      # Allow Nerves.Runtime on host to support development, testing and CI.
      # See config/host.exs for usage.
      {:nerves_runtime, "~> 0.13.12"},

      # NervesSSH is supervised explicitly by NervesGate on every target so its
      # lifecycle and bind address can be tested on the host.
      {:nerves_ssh, "~> 1.3.1"},

      # Device services previously pulled in by nerves_pack. Keeping these
      # explicit prevents nerves_pack from starting NervesSSH during Shoehorn.
      {:mdns_lite, "~> 0.9.2", targets: @all_targets},
      {:nerves_motd, "~> 0.1.17", targets: @all_targets},
      {:nerves_time, "~> 0.4.12", targets: @all_targets},
      {:vintage_net, "~> 0.13.12", targets: @all_targets},
      {:vintage_net_direct, "~> 0.10.8", targets: @all_targets},
      {:vintage_net_ethernet, "~> 0.11.2", targets: @all_targets},
      {:vintage_net_wifi, "~> 0.12.11", targets: @all_targets},

      # Dependencies for specific targets
      # NOTE: It's generally low risk and recommended to follow minor version
      # bumps to Nerves systems. Since these include Linux kernel and Erlang
      # version updates, please review their release notes in case
      # changes to your application are needed.
      {:nerves_system_nerves_gate,
       path: "nerves_system_nerves_gate", runtime: false, targets: :x86_64}
    ]
  end

  def release do
    [
      overwrite: true,
      # Erlang distribution is started only when a persisted cluster cookie exists.
      include_erts: &Nerves.Release.erts/0,
      steps: [&Nerves.Release.init/1, :assemble],
      strip_beams: Mix.env() == :prod or [keep: ["Docs"]]
    ]
  end

  defp before_closing_body_tag(:html) do
    """
    <script defer src="https://cdn.jsdelivr.net/npm/mermaid@10.2.3/dist/mermaid.min.js"></script>
    <script>
      let mermaidInitialized = false;
      let mermaidGraphId = 0;

      window.addEventListener("exdoc:loaded", () => {
        if (!mermaidInitialized) {
          mermaid.initialize({
            startOnLoad: false,
            theme: document.body.className.includes("dark") ? "dark" : "default"
          });
          mermaidInitialized = true;
        }

        for (const codeEl of document.querySelectorAll("pre code.mermaid, pre code.plant_uml")) {
          const preEl = codeEl.parentElement;
          if (preEl.dataset.mermaidState) continue;
          preEl.dataset.mermaidState = "rendering";

          let graphDefinition = codeEl.textContent;
          if (codeEl.classList.contains("plant_uml")) {
            graphDefinition = "stateDiagram-v2\\n" + graphDefinition
              .replace(/^\\s*@startuml\\s*/, "")
              .replace(/\\s*@enduml\\s*$/, "");
          }

          const graphEl = document.createElement("div");
          const graphId = "mermaid-graph-" + mermaidGraphId++;

          mermaid.render(graphId, graphDefinition).then(({svg, bindFunctions}) => {
            graphEl.innerHTML = svg;
            bindFunctions?.(graphEl);
            preEl.insertAdjacentElement("afterend", graphEl);
            preEl.remove();
          }).catch((error) => {
            preEl.dataset.mermaidState = "failed";
            console.warn("Failed to render Mermaid graph", error);
          });
        }
      });
    </script>
    """
  end

  defp before_closing_body_tag(:epub), do: ""

  # Uncomment the following line if using Phoenix > 1.8.
  # defp listeners(:host, :dev), do: [Phoenix.CodeReloader]
  defp listeners(_, _), do: []

  defp aliases() do
    [
      firmware: [
        "nerves_gate.verify_tailscale_bundle",
        "tailwind default --minify",
        "firmware"
      ],
      "assets.build": ["tailwind default --minify"],
      ci: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "test",
        "credo --strict",
        "dialyzer",
        "ex_dna --max-clones 0",
        "reach.check --arch --smells",
        "nerves_gate.qemu_ci"
      ]
    ]
  end
end

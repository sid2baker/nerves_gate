# These commands always run the local development UI, even after firmware builds.
if List.first(System.argv()) in ["dev.ec100", "dev.qemu"] do
  Mix.env(:dev)
  Mix.target(:host)
end

if List.first(System.argv()) == "test.qemu" do
  Mix.env(:test)
  Mix.target(:host)
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
      elixirc_paths:
        if Mix.env() == :test do
          ["lib" | Path.wildcard("test/support/*.ex")]
        else
          ["lib"]
        end,
      deps: deps(),
      releases: [
        nerves_gate: [
          include_erts: &Nerves.erts/0,
          applications: if(Mix.target() == :ec100, do: [nerves_runtime: :transient], else: []),
          steps: [&Nerves.init_release/1, :assemble]
        ]
      ],
      # Integration scripts and the standalone BSP have their own runtimes.
      test_load_filters: [~r{^test/(nerves_gate|nerves_gate_web)/.*_test\.exs$}],
      test_ignore_filters: [~r{^test/(integration|support)/}],
      dialyzer: [
        plt_add_apps: [
          :ex_unit,
          :tailscale,
          :vintage_net,
          :vintage_net_bridge,
          :vintage_net_ethernet
        ]
      ],
      aliases: aliases()
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto], mod: {NervesGate.Application, []}]
  end

  def cli do
    [
      preferred_targets: [
        run: :host,
        test: :host,
        ci: :host,
        "dev.ec100": :host,
        "dev.qemu": :host,
        "test.qemu": :host
      ],
      preferred_envs: [ci: :test, "dev.ec100": :dev, "dev.qemu": :dev, "test.qemu": :test]
    ]
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
      {:lazy_html, ">= 0.1.0", only: :test},
      # tailscale_ex owns its daemon; host simulation must never start the workstation VPN.
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
       path: "test/support/nerves_system_x86_64", runtime: false, targets: :x86_64}
    ]
  end

  defp dev_ec100([]), do: dev_ui(Application.fetch_env!(:nerves_gate, :ec100_node))

  defp dev_qemu([]) do
    unless File.regular?("_build/qemu/gateway.img"),
      do:
        Mix.raise("Prepare _build/qemu/gateway.img and the ng-qemu TAP; see docs/development.md")

    executable =
      System.find_executable("qemu-system-x86_64") || Mix.raise("QEMU is not installed")

    args = ~w(
      -m 1024 -display none -monitor none -serial file:_build/qemu/console.log
      -qmp unix:_build/qemu/qmp.sock,server=on,wait=off
      -drive file=_build/qemu/gateway.img,format=raw,if=virtio
      -netdev user,id=wan -device virtio-net-pci,netdev=wan,id=wan-nic
      -netdev user,id=equipment,net=10.0.3.0/24 -device virtio-net-pci,netdev=equipment
      -netdev tap,id=management,ifname=ng-qemu,script=no,downscript=no
      -device virtio-net-pci,netdev=management
    )

    dev_ui(:"nerves_gate@192.168.77.2")

    Task.start_link(fn ->
      {_, status} = MuonTrap.cmd(executable, args, into: IO.stream(), stderr_to_stdout: true)
      System.stop(status)
    end)
  end

  defp test_qemu([]) do
    # Build current source, never silently test yesterday's firmware.
    {_, build_status} =
      System.cmd("mix", ["firmware", "--overwrite"],
        env: [
          {"MIX_TARGET", "x86_64"},
          {"MIX_ENV", "dev"},
          {"NERVES_GATE_DEVICE_NODE", nil},
          {"NERVES_GATE_BACKEND_NODE", nil}
        ],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    if build_status != 0, do: Mix.raise("QEMU firmware build failed")

    {_, status} =
      System.cmd(
        "unshare",
        [
          "--user",
          "--map-root-user",
          "--net",
          "mix",
          "do",
          "compile",
          "+",
          "run",
          "--no-start",
          "test/integration/qemu_test.exs"
        ],
        env: [
          {"MIX_TARGET", "host"},
          {"MIX_ENV", "test"},
          {"NERVES_GATE_BACKEND_NODE", nil},
          {"NERVES_GATE_HOST_NETNS", File.read_link!("/proc/self/ns/net")}
        ],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("QEMU regression failed (exit #{status})")
  end

  defp dev_ui(backend) do
    backend = to_string(backend)
    [_, address] = String.split(backend, "@", parts: 2)
    {:ok, socket} = :gen_udp.open(0, [:inet])

    ip =
      try do
        :ok = :gen_udp.connect(socket, String.to_charlist(address), 9)
        {:ok, {ip, _}} = :inet.sockname(socket)
        ip
      after
        :gen_udp.close(socket)
      end

    System.put_env("NERVES_GATE_BACKEND_NODE", backend)
    Mix.Task.rerun("loadconfig")
    Mix.Task.rerun("compile", ["--force"])
    {_, 0} = System.cmd("epmd", ["-daemon"])
    {:ok, _} = Node.start(:"nerves_gate_ui@#{:inet.ntoa(ip)}", name_domain: :longnames)
  end

  defp aliases() do
    [
      test: ["test --no-start"],
      "test.qemu": [&test_qemu/1],
      "dev.ec100": [&dev_ec100/1, "phx.server"],
      "dev.qemu": [&dev_qemu/1, "phx.server"],
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

defmodule NervesGate.FirmwareBuildTest do
  use ExUnit.Case, async: false

  @target_config Path.expand("../../config/target.exs", __DIR__)

  defp with_env(env, fun) do
    previous = for {key, _value} <- env, do: {key, System.get_env(key)}
    System.put_env(env)

    try do
      fun.()
    after
      System.put_env(previous)
    end
  end

  test "target builds use SOURCE_DATE_EPOCH when supplied" do
    with_env([{"SOURCE_DATE_EPOCH", "1700000000"}], fn ->
      config = Config.Reader.read!(@target_config, target: :ec100, env: :prod)
      assert config[:nerves][:source_date_epoch] == "1700000000"
      assert config[:nerves][:firmware][:rootfs_type] == {:squashfs, ["-no-xattrs", "-quiet"]}
      assert config[:tailscale][:daemon_path] == "/usr/sbin/tailscaled"
      assert config[:tailscale][:data_dir] == "/data/tailscale_ex"
      assert config[:tailscale][:socket] == "/run/tailscale/tailscaled.sock"
      assert config[:tailscale][:manage_daemon]
      assert config[:tailscale][:tun] == :kernel
    end)
  end

  test "firmware enables RingLogger persistence without changing host logging" do
    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!(@target_config, target: target, env: :prod)
      assert config[:logger][RingLogger][:persist_path] == "/data/ring_logger.log"
      assert config[:logger][RingLogger][:persist_seconds] == 5
      refute Keyword.has_key?(config[:nerves_gate], :logger)
    end

    refute Application.get_env(:logger, RingLogger, [])[:persist_path]
  end

  test "routing setup has no boot script and is inert on the host" do
    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!(@target_config, target: target, env: :prod)
      refute Keyword.has_key?(config[:nerves][:erlinit], :pre_run_exec)
    end

    refute File.exists?(
             Path.expand("../../rootfs_overlay/common/usr/sbin/nerves-gate-routing", __DIR__)
           )

    assert NervesGate.Network.Vintage.prepare_routing() == :ok
  end

  test "HTTP startup does not depend on cellular support or a boot marker" do
    runtime = Path.expand("../../config/runtime.exs", __DIR__)

    for target <- [:host, :ec100, :x86_64] do
      config = Config.Reader.read!(runtime, target: target, env: :prod)
      refute Keyword.has_key?(config[:nerves_gate][NervesGateWeb.Endpoint], :server)
    end

    config = Config.Reader.read!(@target_config, target: :ec100, env: :prod)
    assert config[:nerves_gate][:cellular] == nil

    assert config[:vintage_net][:route_metric_fun] ==
             {NervesGate.Network.RouteMetric, :compute_metric, 2}
  end

  test "target builds default to the source commit timestamp" do
    {timestamp, 0} = System.cmd("git", ["log", "-1", "--format=%ct"])

    with_env([{"SOURCE_DATE_EPOCH", nil}], fn ->
      config = Config.Reader.read!(@target_config, target: :ec100, env: :prod)
      assert config[:nerves][:source_date_epoch] == String.trim(timestamp)
    end)
  end

  test "invalid source timestamps fail before firmware assembly" do
    for value <- ["", "tomorrow", "-1", "123oops"] do
      with_env([{"SOURCE_DATE_EPOCH", value}], fn ->
        assert_raise RuntimeError, ~r"SOURCE_DATE_EPOCH must be", fn ->
          Config.Reader.read!(@target_config, target: :ec100, env: :prod)
        end
      end)
    end
  end

  test "distribution has no build-time identity and uses OTP's persistent cookie" do
    args = Path.expand("../../rel/vm.args.eex", __DIR__) |> EEx.eval_file()
    lines = String.split(args, "\n")
    assert "-kernel inet_dist_listen_min 9100 inet_dist_listen_max 9100" in lines
    refute "-nocookie" in lines
    refute args =~ "-name "
    refute args =~ "-sname "
    refute args =~ "-setcookie"
    refute args =~ "NERVES_GATE_NODE"
    assert "-kernel shell_history enabled" in lines
    assert "-heart -env HEART_BEAT_TIMEOUT 30" in lines
  end

  test "firmware enables the startup guard required by the Heart init timeout" do
    vm_args = Path.expand("../../rel/vm.args.eex", __DIR__) |> File.read!() |> String.split("\n")
    assert "-env HEART_INIT_TIMEOUT 600" in vm_args
    assert "-heart -env HEART_BEAT_TIMEOUT 30" in vm_args

    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!(@target_config, target: target, env: :prod)
      assert config[:nerves_runtime][:startup_guard_enabled] == true
    end
  end

  test "firmware serves HTTP on every IPv4 interface while host development stays loopback-only" do
    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!(@target_config, target: target, env: :prod)
      assert config[:nerves_gate][NervesGateWeb.Endpoint][:http] == [ip: {0, 0, 0, 0}, port: 4000]
      refute Keyword.has_key?(config[:nerves_gate], :management_interface)
    end

    assert Application.fetch_env!(:nerves_gate, NervesGateWeb.Endpoint)[:http] == [
             ip: {127, 0, 0, 1},
             port: 4000
           ]
  end

  test "EC100 boot configures only USB provisioning, leaving the LAN to the network manager" do
    config = Config.Reader.read!(@target_config, target: :ec100, env: :prod)
    assert config[:nerves_gate][:target] == :ec100
    assert config[:vintage_net][:persistence] == VintageNet.Persistence.FlatFile
    assert config[:vintage_net][:config] == [{"usb0", %{type: VintageNetDirect}}]
  end

  test "x86 firmware does not assume a USB gadget exists" do
    config = Config.Reader.read!(@target_config, target: :x86_64, env: :prod)
    assert config[:nerves_gate][:target] == :x86_64
    assert config[:vintage_net][:config] == []
  end

  test "QEMU development has a default node without changing EC100 or production" do
    with_env([{"NERVES_GATE_DEVICE_NODE", nil}], fn ->
      dev = Config.Reader.read!(@target_config, target: :x86_64, env: :dev)
      assert dev[:nerves_gate][:development_node] == :"nerves_gate@192.168.77.2"
      ec100 = Config.Reader.read!(@target_config, target: :ec100, env: :dev)
      refute ec100[:nerves_gate][:development_node]
      prod = Config.Reader.read!(@target_config, target: :x86_64, env: :prod)
      refute prod[:nerves_gate][:development_node]
    end)
  end

  test "explicit distribution identity and the third QEMU NIC are development-only" do
    with_env([{"NERVES_GATE_DEVICE_NODE", "nerves_gate@192.168.77.2"}], fn ->
      dev = Config.Reader.read!(@target_config, target: :x86_64, env: :dev)
      assert dev[:nerves_gate][:development_node] == :"nerves_gate@192.168.77.2"
      assert [{"eth2", management}] = dev[:vintage_net][:config]
      assert management.ipv4 == %{method: :static, address: "192.168.77.2", prefix_length: 24}

      for target <- [:ec100, :x86_64] do
        prod = Config.Reader.read!(@target_config, target: target, env: :prod)
        refute prod[:nerves_gate][:development_node]
        refute prod[:nerves_gate][:backend_node]
        refute prod[:nerves_gate][NervesGateWeb.Endpoint][:code_reloader]
      end
    end)
  end

  test "the public distribution cookie is restricted to development builds" do
    config_file = Path.expand("../../config/config.exs", __DIR__)

    for {env, cookie} <- [dev: :mycookie, test: nil, prod: nil] do
      config = Config.Reader.read!(config_file, target: :host, env: env)
      assert config[:nerves_gate][:distribution_cookie] == cookie
    end
  end

  test "development commands configure the host before starting Phoenix" do
    aliases = NervesGate.MixProject.project()[:aliases]
    cli = NervesGate.MixProject.cli()

    for command <- [:"dev.ec100", :"dev.qemu"] do
      assert [setup, "phx.server"] = aliases[command]
      assert is_function(setup, 1)
      assert cli[:preferred_targets][command] == :host
      assert cli[:preferred_envs][command] == :dev
    end
  end

  test "development tooling is restricted to host dev and loopback" do
    deps = NervesGate.MixProject.project()[:deps]

    for name <- [:tidewave, :phoenix_live_reload] do
      {^name, _, opts} = List.keyfind(deps, name, 0)
      assert opts[:only] == :dev
      assert opts[:targets] == :host
    end

    dev =
      Config.Reader.read!(Path.expand("../../config/dev.exs", __DIR__), env: :dev, target: :host)

    assert dev[:nerves_gate][:ec100_node] == :"nerves_gate@100.88.166.70"
    assert dev[:nerves_gate][NervesGateWeb.Endpoint][:code_reloader]
    assert dev[:nerves_gate][NervesGateWeb.Endpoint][:http][:ip] == {127, 0, 0, 1}
  end

  test "firmware overlays include shared console setup and only the selected target binaries" do
    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!(@target_config, target: target, env: :prod)
      assert [common, binaries] = config[:nerves][:firmware][:rootfs_overlay]
      assert common == Path.expand("../../rootfs_overlay/common", __DIR__)
      assert binaries == Path.expand("../../rootfs_overlay/#{target}", __DIR__)
      assert File.regular?(Path.join(common, "etc/iex.exs"))
      assert config[:nerves_ssh][:iex_opts] == [dot_iex: "/etc/iex.exs"]
    end
  end

  test "host application does not start a Tailscale daemon" do
    refute :tailscale in Enum.map(Application.started_applications(), &elem(&1, 0))
  end

  test "all targets share a lockfile and use declarative system dependencies" do
    previous = Mix.target()

    try do
      for target <- [:host, :ec100, :x86_64] do
        Mix.target(target)
        project = NervesGate.MixProject.project()
        assert Keyword.get(project, :lockfile, "mix.lock") == "mix.lock"

        assert {:nerves_system_ec100, ec100} =
                 List.keyfind(project[:deps], :nerves_system_ec100, 0)

        assert {:nerves_system_x86_64, x86} =
                 List.keyfind(project[:deps], :nerves_system_x86_64, 0)

        assert ec100[:targets] == :ec100
        assert x86[:targets] == :x86_64
        assert x86[:path] == "test/support/nerves_system_x86_64"
        assert {:tailscale, tailscale} = List.keyfind(project[:deps], :tailscale, 0)
        assert tailscale[:runtime] == (target != :host)
      end
    after
      Mix.target(previous)
    end
  end

  test "release uses the native Nerves initialization step" do
    assert Mix.Project.config()[:releases][:nerves_gate][:steps] == [
             &Nerves.init_release/1,
             :assemble
           ]
  end
end

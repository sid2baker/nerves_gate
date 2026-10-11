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
      config = Config.Reader.read!(@target_config, target: :ec100)
      assert config[:nerves][:source_date_epoch] == "1700000000"
      assert config[:nerves][:firmware][:rootfs_type] == {:squashfs, ["-no-xattrs", "-quiet"]}
      assert config[:tailscale][:daemon_path] == "/usr/sbin/tailscaled"
      assert config[:tailscale][:data_dir] == "/data/tailscale_ex"
      assert config[:tailscale][:socket] == "/run/tailscale/tailscaled.sock"
      assert config[:tailscale][:manage_daemon]
      assert config[:tailscale][:tun] == :kernel
    end)
  end

  test "target builds default to the source commit timestamp" do
    {timestamp, 0} = System.cmd("git", ["log", "-1", "--format=%ct"])

    with_env([{"SOURCE_DATE_EPOCH", nil}], fn ->
      config = Config.Reader.read!(@target_config, target: :ec100)
      assert config[:nerves][:source_date_epoch] == String.trim(timestamp)
    end)
  end

  test "invalid source timestamps fail before firmware assembly" do
    for value <- ["", "tomorrow", "-1", "123oops"] do
      with_env([{"SOURCE_DATE_EPOCH", value}], fn ->
        assert_raise RuntimeError, ~r"SOURCE_DATE_EPOCH must be", fn ->
          Config.Reader.read!(@target_config, target: :ec100)
        end
      end)
    end
  end

  test "firmware enables the startup guard required by the Heart init timeout" do
    vm_args = Path.expand("../../rel/vm.args.eex", __DIR__) |> File.read!() |> String.split("\n")
    assert "-env HEART_INIT_TIMEOUT 600" in vm_args
    assert "-heart -env HEART_BEAT_TIMEOUT 30" in vm_args

    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!(@target_config, target: target)
      assert config[:nerves_runtime][:startup_guard_enabled] == true
    end
  end

  test "firmware serves HTTP on every IPv4 interface while host development stays loopback-only" do
    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!(@target_config, target: target)
      assert config[:nerves_gate][NervesGateWeb.Endpoint][:http] == [ip: {0, 0, 0, 0}, port: 4000]
      refute Keyword.has_key?(config[:nerves_gate], :management_interface)
    end

    assert Application.fetch_env!(:nerves_gate, NervesGateWeb.Endpoint)[:http] == [
             ip: {127, 0, 0, 1},
             port: 4000
           ]
  end

  test "EC100 boot configures only USB provisioning, leaving the LAN to the network manager" do
    config = Config.Reader.read!(@target_config, target: :ec100)
    assert config[:nerves_gate][:target] == :ec100
    assert config[:vintage_net][:persistence] == VintageNet.Persistence.FlatFile
    assert config[:vintage_net][:config] == [{"usb0", %{type: VintageNetDirect}}]
  end

  test "x86 firmware does not assume a USB gadget exists" do
    config = Config.Reader.read!(@target_config, target: :x86_64)
    assert config[:nerves_gate][:target] == :x86_64
    assert config[:vintage_net][:config] == []
  end

  test "firmware overlays include shared console setup and only the selected target binaries" do
    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!(@target_config, target: target)
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

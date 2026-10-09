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

  test "EC100 boot configures only USB provisioning, leaving the LAN to the network manager" do
    config = Config.Reader.read!(@target_config, target: :ec100)
    assert config[:nerves_gate][:target] == :ec100
    assert config[:vintage_net][:persistence] == VintageNet.Persistence.Null
    assert config[:vintage_net][:config] == [{"usb0", %{type: VintageNetDirect}}]
  end

  test "x86 firmware does not assume a USB gadget exists" do
    config = Config.Reader.read!(@target_config, target: :x86_64)
    assert config[:nerves_gate][:target] == :x86_64
    assert config[:vintage_net][:config] == []
  end

  test "firmware includes a static IEx overlay alongside target-specific Tailscale binaries" do
    for target <- [:ec100, :x86_64] do
      config = Config.Reader.read!(@target_config, target: target)
      assert [static, generated] = config[:nerves][:firmware][:rootfs_overlay]
      assert static == Path.expand("../../rootfs_overlay", __DIR__)
      assert generated == Path.join(Mix.Project.build_path(), "tailscale_rootfs")
      assert File.regular?(Path.join(static, "etc/iex.exs"))
      assert config[:nerves_ssh][:iex_opts] == [dot_iex: "/etc/iex.exs"]
    end
  end

  test "host application does not start a Tailscale daemon" do
    refute :tailscale in Enum.map(Application.started_applications(), &elem(&1, 0))
  end

  test "Tailscale installer recognizes both firmware toolchains without using host architecture" do
    for {target, triple, expected} <- [
          {:ec100, "armv7-nerves-linux-gnueabihf", "arm"},
          {:x86_64, "x86_64-nerves-linux-musl", "amd64"}
        ] do
      assert Mix.Tasks.Tailscale.Install.architecture!(target, triple, "aarch64-apple-darwin") ==
               expected
    end
  end

  test "firmware preparation does nothing on the host" do
    [prepare | _] = Mix.Project.config()[:releases][:nerves_gate][:steps]
    release = %Mix.Release{name: :nerves_gate}
    assert prepare.(release) == release
  end
end

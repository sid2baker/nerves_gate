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
      config = Config.Reader.read!(@target_config)
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
      config = Config.Reader.read!(@target_config)
      assert config[:nerves][:source_date_epoch] == String.trim(timestamp)
    end)
  end

  test "invalid source timestamps fail before firmware assembly" do
    for value <- ["", "tomorrow", "-1", "123oops"] do
      with_env([{"SOURCE_DATE_EPOCH", value}], fn ->
        assert_raise RuntimeError, ~r"SOURCE_DATE_EPOCH must be", fn ->
          Config.Reader.read!(@target_config)
        end
      end)
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

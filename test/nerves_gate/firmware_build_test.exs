defmodule NervesGate.FirmwareBuildTest do
  use ExUnit.Case, async: false

  @target_config Path.expand("../../config/target.exs", __DIR__)
  @packager Path.expand("../../scripts/prepare_tailscale.sh", __DIR__)

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

  @tag :tmp_dir
  test "packaging rejects unknown architectures without downloading", %{tmp_dir: tmp} do
    {output, status} = System.cmd("sh", [@packager, "unknown", tmp, tmp], stderr_to_stdout: true)
    assert status != 0
    assert output =~ "Unsupported Tailscale target"
    refute File.exists?(Path.join(tmp, "usr/sbin/tailscaled"))
  end

  @tag :tmp_dir
  test "packaging rejects corrupt cached archives without installing", %{tmp_dir: tmp} do
    overlay = Path.join(tmp, "overlay")
    cache = Path.join(tmp, "cache")
    File.mkdir_p!(cache)

    for {target, arch} <- [{"ec100", "arm"}, {"x86_64", "amd64"}] do
      File.write!(Path.join(cache, "tailscale_1.102.3_#{arch}.tgz"), "corrupt archive")

      {output, status} =
        System.cmd("sh", [@packager, target, overlay, cache], stderr_to_stdout: true)

      assert status != 0
      assert output =~ "checksum mismatch"
      refute File.exists?(Path.join(overlay, "usr/sbin/tailscaled"))
      assert Path.wildcard(Path.join(cache, ".tailscale.*")) == []
    end
  end
end

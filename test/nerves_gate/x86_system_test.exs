defmodule NervesGate.X86SystemTest do
  use ExUnit.Case, async: true

  @system Path.expand("../support/nerves_system_x86_64", __DIR__)

  # These are source-configuration guards, not a substitute for checking
  # Buildroot's generated .config or booting the firmware in QEMU.
  test "the test system selects EC100's shared Nerves and gateway userspace" do
    config = config("nerves_defconfig")

    for key <- ~w(
          BR2_REPRODUCIBLE BR2_INIT_NONE BR2_TARGET_ROOTFS_TAR
          BR2_PACKAGE_BRIDGE_UTILS BR2_PACKAGE_IPTABLES BR2_PACKAGE_LIBMNL
          BR2_PACKAGE_LIBNL BR2_PACKAGE_E2FSPROGS BR2_PACKAGE_CA_CERTIFICATES
          BR2_PACKAGE_NBTTY BR2_PACKAGE_NERVES_CONFIG
        ) do
      assert config[key] == "y", "#{key} must remain enabled"
    end

    assert config["BR2_PACKAGE_IPTABLES_NFTABLES"] == "n"

    assert config["BR2_ROOTFS_DEVICE_TABLE"] ==
             ~s("${BR2_EXTERNAL_NERVES_PATH}/board/nerves-common/device_table.txt")

    assert config["BR2_NERVES_ADDITIONAL_IMAGE_FILES"] ==
             ~s("${NERVES_DEFCONFIG_DIR}/fwup.conf ${NERVES_DEFCONFIG_DIR}/fwup-ops.conf")
  end

  test "the gateway fragment covers dual-stack routing, marks and the legacy firewall" do
    config = config("linux/gateway.fragment")

    for key <- ~w(
          CONFIG_STRICT_KERNEL_RWX CONFIG_BRIDGE CONFIG_TUN
          CONFIG_IP_ADVANCED_ROUTER CONFIG_IP_MULTIPLE_TABLES CONFIG_IPV6_MULTIPLE_TABLES
          CONFIG_NETFILTER_ADVANCED CONFIG_NF_CONNTRACK CONFIG_NF_CONNTRACK_MARK CONFIG_NF_NAT
          CONFIG_NETFILTER_XT_MARK CONFIG_NETFILTER_XT_CONNMARK
          CONFIG_NETFILTER_XT_MATCH_COMMENT CONFIG_NETFILTER_XT_MATCH_CONNTRACK
          CONFIG_NETFILTER_XT_TARGET_MASQUERADE CONFIG_NETFILTER_XT_TARGET_TCPMSS
          CONFIG_IP_NF_IPTABLES CONFIG_IP_NF_FILTER CONFIG_IP_NF_TARGET_REJECT
          CONFIG_IP_NF_NAT CONFIG_IP_NF_MANGLE
          CONFIG_IP6_NF_IPTABLES CONFIG_IP6_NF_FILTER CONFIG_IP6_NF_TARGET_REJECT
          CONFIG_IP6_NF_NAT CONFIG_IP6_NF_MANGLE
        ) do
      assert config[key] == "y", "#{key} must remain built in"
    end

    for key <- ~w(
          CONFIG_BRIDGE_NETFILTER CONFIG_MODULES CONFIG_SOFT_WATCHDOG
          CONFIG_DRM CONFIG_SOUND CONFIG_BT CONFIG_WLAN CONFIG_WIRELESS CONFIG_RFKILL
        ) do
      assert config[key] == "n", "#{key} must remain disabled"
    end
  end

  test "EC100 alignment preserves the x86 boot and virtio configuration" do
    build = config("nerves_defconfig")
    kernel = Map.merge(config("linux-6.18.defconfig"), config("linux/gateway.fragment"))

    for key <- ~w(BR2_x86_64 BR2_TOOLCHAIN_EXTERNAL_CUSTOM_MUSL BR2_TARGET_GRUB2) do
      assert build[key] == "y"
    end

    for key <- ~w(CONFIG_VIRTIO_BLK CONFIG_VIRTIO_NET CONFIG_SERIAL_8250_CONSOLE CONFIG_VFAT_FS) do
      assert kernel[key] == "y"
    end
  end

  test "erlinit shares the EC100 console and diagnostics without copying its partition layout" do
    lines =
      @system
      |> Path.join("rootfs_overlay/etc/erlinit.config")
      |> File.read!()
      |> String.split("\n")

    for line <- [
          "-c ttyS0",
          ~s(-s "/usr/bin/nbtty"),
          "--update-clock",
          "--shutdown-report /root/shutdown.txt",
          "-e ERL_CRASH_DUMP=/root/erl_crash.dump;ERL_CRASH_DUMP_SECONDS=5",
          "-m /dev/rootdisk0p1:/boot/grub:vfat:ro,nodev,noexec,nosuid:",
          "-m /dev/rootdisk0p4:/root:ext4:nodev:"
        ] do
      assert line in lines
    end
  end

  defp config(file) do
    @system
    |> Path.join(file)
    |> File.read!()
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      cond do
        String.starts_with?(line, "# ") and String.ends_with?(line, " is not set") ->
          [{line |> String.trim_leading("# ") |> String.trim_trailing(" is not set"), "n"}]

        String.starts_with?(line, ["CONFIG_", "BR2_"]) ->
          [key, value] = String.split(line, "=", parts: 2)
          [{key, value}]

        true ->
          []
      end
    end)
    |> Map.new()
  end
end

defmodule EM300LayoutTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Em300.Flash

  # Flash.layout/0 is parsed from bootstrap/parameter.txt, the single layout
  # source; every other consumer is checked against it here.

  test "GPT parameter matches the layout and leaves the Rockchip tail reserved" do
    assert :ok == Flash.check_parameter!(File.read!("bootstrap/parameter.txt"))

    assert_raise Mix.Error, fn ->
      Flash.check_parameter!("CMDLINE: mtdparts=rk29xxnand:0x00002000@0x00002000(uboot)\n")
    end

    # Writes and U-Boot address partitions by these names.
    assert Enum.map(Flash.layout(), &elem(&1, 0)) == ~w(uboot env kernel_a kernel_b ubi)
    {_, start, count} = List.last(Flash.layout())
    assert (start + count) * 512 == 0x1FF00000
    assert Flash.board().sectors.first == start + count

    Flash.layout()
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{_, start, count}, {_, next, _}] -> assert start + count == next end)
  end

  test "device-tree partitions match the GPT, after the 4 MiB IDB area" do
    dts = File.read!("dts/rk3506-em300.dts")

    partitions =
      Regex.scan(~r/label = "(\w+)";\s*reg = <0x([0-9a-f]+) 0x([0-9a-f]+)>;/, dts)
      |> Enum.map(fn [_, name, start, size] ->
        {name, div(String.to_integer(start, 16), 512), div(String.to_integer(size, 16), 512)}
      end)

    assert partitions == [{"idblock", 0, 0x2000} | Flash.layout()]

    # Linux numbers MTD devices in this order; fwup and fw_env.config rely on it.
    assert Enum.find_index(partitions, &(elem(&1, 0) == "env")) == 2
    assert Enum.find_index(partitions, &(elem(&1, 0) == "kernel_a")) == 3
    assert Enum.find_index(partitions, &(elem(&1, 0) == "kernel_b")) == 4
    assert Enum.find_index(partitions, &(elem(&1, 0) == "ubi")) == 5
  end

  test "U-Boot, fwup and fw_env.config agree on the environment and kernel slots" do
    fragment = File.read!("bootstrap/uboot.config.fragment")

    patch =
      File.read!("bootstrap/patches/uboot/0001-em300-legacy-config-and-current-compiler.patch")

    {_, env_start, _} = List.keyfind(Flash.layout(), "env", 0)

    assert fragment =~ "CONFIG_ENV_OFFSET=0x#{hex(env_start * 512)}\n"
    assert fragment =~ "CONFIG_ENV_SIZE=0x00020000\n"
    assert patch =~ "+#define CONFIG_ENV_OFFSET_REDUND 0x#{hex(env_start * 512 + 0x20000)}\n"

    assert File.read!("rootfs_overlay/etc/fw_env.config") =~
             ~r{/dev/mtdblock2\s+0x00000000\s+0x00020000\s+0x00020000\s+/dev/mtdblock2\s+0x00020000\s+0x00020000\s+0x00020000}

    fwup = File.read!("fwup.conf")
    {_, a, _} = List.keyfind(Flash.layout(), "kernel_a", 0)
    {_, b, _} = List.keyfind(Flash.layout(), "kernel_b", 0)
    assert fwup =~ ~s{define(FIT_A_SECTOR, "0x#{Integer.to_string(a, 16) |> String.downcase()}")}
    assert fwup =~ ~s{define(FIT_B_SECTOR, "0x#{Integer.to_string(b, 16) |> String.downcase()}")}
  end

  test "real fwup creates the factory environment and gates upgrades" do
    tmp = tmp!()
    firmware = firmware!(tmp)
    fwup = System.find_executable("fwup")
    env = Path.join(tmp, "env.img")
    File.write!(env, :binary.copy(<<0xFF>>, 0x800 * 512))

    assert {_, 0} = System.cmd(fwup, ["-a", "-q", "-i", firmware, "-t", "factory-env", "-d", env])

    for offset <- [0, 0x20000] do
      <<crc::little-32, _flag, data::binary>> = binary_part(File.read!(env), offset, 0x20000)
      assert :erlang.crc32(data) == crc
      entries = :binary.split(data, <<0>>, [:global])

      for entry <- [
            "nerves_fw_active=a",
            "nerves_fw_devpath=/dev/mtdblock2",
            "a.nerves_fw_platform=em300",
            "a.nerves_fw_application_part0_devpath=/dev/ubi0_2",
            "a.nerves_fw_application_part0_fstype=ubifs",
            "fit_a_sector=0x4800",
            "fit_b_sector=0xc800",
            "boot_a=setenv rootvol rootfs_a; setenv rootdev /dev/ubiblock0_0; setenv fit_sector $fit_a_sector; run boot_slot"
          ],
          do: assert(entry in entries, "env missing #{entry}")

      # Escaped ${name} must survive both archive creation and application.
      assert Enum.any?(entries, &(&1 =~ "mtd_blk read $kernel_addr_r $fit_sector $fit_blocks"))
      assert Enum.any?(entries, &(&1 =~ "ubi.block=0,$rootvol root=$rootdev"))
    end

    # fwup cannot install the NAND layout, and slot writes need --unsafe.
    assert {_, status} =
             System.cmd(fwup, ["-a", "-q", "-i", firmware, "-t", "complete", "-d", env],
               stderr_to_stdout: true
             )

    assert status != 0

    assert {output, status} =
             System.cmd(fwup, ["-a", "-q", "-i", firmware, "-t", "upgrade", "-d", env],
               stderr_to_stdout: true
             )

    assert status != 0 and output =~ "requires --unsafe"
  end

  test "ops.fw reports, validates and reverts on the env partition" do
    tmp = tmp!()
    firmware = firmware!(tmp)
    fwup = System.find_executable("fwup")
    ops = Path.join(tmp, "ops.fw")
    assert {_, 0} = System.cmd(fwup, ["-c", "-f", "fwup-ops.conf", "-o", ops])
    env = Path.join(tmp, "env.img")
    File.write!(env, :binary.copy(<<0xFF>>, 0x800 * 512))
    assert {_, 0} = System.cmd(fwup, ["-a", "-q", "-i", firmware, "-t", "factory-env", "-d", env])

    assert {"fwup: a\n", 0} = System.cmd(fwup, ["-a", "-q", "-i", ops, "-t", "status", "-d", env])
    assert {_, 0} = System.cmd(fwup, ["-a", "-q", "-i", ops, "-t", "validate", "-d", env])

    # Slot B was never installed, so revert must refuse.
    assert {_, status} =
             System.cmd(fwup, ["-a", "-q", "-i", ops, "-t", "revert", "-d", env],
               stderr_to_stdout: true
             )

    assert status != 0
  end

  test "factory staging builds the UBI image and env from the archive" do
    case System.find_executable("ubinize") do
      nil ->
        IO.puts("skipping UBI staging check: ubinize (mtd-utils) is not installed")

      _ ->
        tmp = tmp!()
        firmware = firmware!(tmp)
        images = Path.join(tmp, "images")

        hashes =
          for name <- ["em300-loader.bin", "u-boot.itb", "em300-parameter.txt"] do
            path = Path.join(images, name)
            unless name == "em300-parameter.txt", do: File.write!(path, name)
            "#{sha256(File.read!(path))}  #{name}\n"
          end

        File.write!(Path.join(images, "bootloader.sha256"), hashes)
        staged = Flash.prepare!(firmware, images, 0x100000, Path.join(tmp, "staged"))

        assert_raise Mix.Error, ~r/Unsupported NAND capacity/, fn ->
          Flash.prepare!(firmware, images, 0x80000, Path.join(tmp, "small"))
        end

        assert Enum.map(staged.writes, &elem(&1, 0)) == ["uboot", "kernel_a", "ubi", "env"]
        {_, ubi} = List.keyfind(staged.writes, "ubi", 0)
        # UBI erase-counter header magic.
        assert binary_part(File.read!(ubi), 0, 4) == "UBI#"
    end
  end

  test "MaskROM detection and capacity checks fail closed" do
    assert Flash.device!("DevNo=1\tVid=0x2207,Pid=0x350f,LocationID=101\tMaskrom\n") =~ "Maskrom"
    assert_raise Mix.Error, fn -> Flash.device!("DevNo=1\tVid=0x2207,Pid=0x350f\tLoader\n") end
    assert_raise Mix.Error, fn -> Flash.device!("") end
    assert Flash.check_capacity!(0x100000) == 0x100000
    assert_raise Mix.Error, fn -> Flash.check_capacity!(0x80000) end
    assert_raise Mix.Error, fn -> Flash.check_capacity!(0x200000) end
  end

  defp firmware!(tmp) do
    images = Path.join(tmp, "images")
    File.mkdir_p!(images)
    File.write!(Path.join(images, "em300.itb"), :binary.copy(<<0xAB>>, 4096))
    File.write!(Path.join(images, "rootfs.squashfs"), :binary.copy(<<0xCD>>, 8192))
    File.cp!("bootstrap/parameter.txt", Path.join(images, "em300-parameter.txt"))
    firmware = Path.join(tmp, "test.fw")
    fwup = System.find_executable("fwup") || flunk("fwup required")

    {output, status} =
      System.cmd(fwup, ["-c", "-f", "fwup.conf", "-o", firmware],
        stderr_to_stdout: true,
        env: [
          {"NERVES_SYSTEM", tmp},
          {"NERVES_SDK_VERSION", "test"},
          {"NERVES_FW_VCS_IDENTIFIER", "test"},
          {"NERVES_FW_MISC", "test"}
        ]
      )

    assert status == 0, output
    firmware
  end

  defp tmp! do
    tmp = Path.join(System.tmp_dir!(), "em300-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    tmp
  end

  defp hex(value), do: value |> Integer.to_string(16) |> String.pad_leading(8, "0")
  defp sha256(data), do: :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
end

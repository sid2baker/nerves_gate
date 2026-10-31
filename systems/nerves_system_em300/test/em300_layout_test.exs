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
    assert Enum.map(Flash.layout(), &elem(&1, 0)) == ~w(uboot env ubi)
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
    assert Enum.find_index(partitions, &(elem(&1, 0) == "ubi")) == 3
  end

  test "U-Boot attaches the same UBI partition and both sides name the same volumes" do
    fragment = File.read!("bootstrap/uboot.config.fragment")
    {_, start, count} = List.keyfind(Flash.layout(), "ubi", 0)

    assert fragment =~
             ~s{CONFIG_MTDPARTS_DEFAULT="mtdparts=spi-nand0:0x#{hex(count * 512) |> String.downcase()}@0x#{hex(start * 512) |> String.downcase()}(ubi)"\n}

    assert fragment =~ "CONFIG_CMD_UBI=y\n"

    volumes =
      Regex.scan(~r/vol_id=(\d+)\n.*\nvol_name=(\w+)/, Flash.ubinize_config("r", "k"))
      |> Map.new(fn [_, id, name] -> {name, "/dev/ubi0_#{id}"} end)

    assert volumes == %{
             "rootfs_a" => "/dev/ubi0_0",
             "rootfs_b" => "/dev/ubi0_1",
             "data" => "/dev/ubi0_2",
             "kernel_a" => "/dev/ubi0_3",
             "kernel_b" => "/dev/ubi0_4"
           }

    fwup = File.read!("fwup.conf")

    for {slot, rootfs, kernel} <- [{"a", "rootfs_a", "kernel_a"}, {"b", "rootfs_b", "kernel_b"}] do
      [task] = Regex.run(~r/task upgrade\.#{slot} \{.*?\n\}/s, fwup)
      assert task =~ ~s|on-resource rootfs.img { ubi_volume_write("#{volumes[rootfs]}") }|
      assert task =~ ~s|on-resource em300.itb { ubi_volume_write("#{volumes[kernel]}") }|
    end

    assert File.read!("rootfs_overlay/etc/erlinit.config") =~ "-m #{volumes["data"]}:/root:ubifs"
    refute File.exists?("rootfs_overlay/usr/sbin/em300-write-kernel")
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
            "em300_layout=ubi-kernels",
            "boot_a=setenv rootvol rootfs_a; setenv rootdev /dev/ubiblock0_0; setenv kernelvol kernel_a; run boot_slot",
            "boot_b=setenv rootvol rootfs_b; setenv rootdev /dev/ubiblock0_1; setenv kernelvol kernel_b; run boot_slot"
          ],
          do: assert(entry in entries, "env missing #{entry}")

      # Escaped ${name} must survive both archive creation and application.
      assert Enum.any?(entries, &(&1 =~ "ubi part ubi && ubi read $kernel_addr_r $kernelvol"))
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

    # NAND installed before UBI kernel volumes is rejected, never rewritten.
    old = Path.join(tmp, "old-env.img")
    File.write!(old, :binary.copy(<<0xFF>>, 0x800 * 512))
    old_conf = Path.join(tmp, "old-env.conf")
    old_fw = Path.join(tmp, "old-env.fw")

    File.write!(old_conf, """
    uboot-environment env {
        block-offset = 0
        block-count = 256
        block-offset-redund = 256
    }
    task env {
        on-init {
            uboot_clearenv(env)
            uboot_setenv(env, "nerves_fw_active", "a")
            uboot_setenv(env, "upgrade_available", "0")
            uboot_setenv(env, "a.nerves_fw_platform", "em300")
            uboot_setenv(env, "a.nerves_fw_architecture", "arm")
        }
    }
    """)

    assert {_, 0} = System.cmd(fwup, ["-c", "-f", old_conf, "-o", old_fw])
    assert {_, 0} = System.cmd(fwup, ["-a", "-q", "-i", old_fw, "-t", "env", "-d", old])

    assert {output, status} =
             System.cmd(
               fwup,
               ["-a", "-q", "--unsafe", "-i", firmware, "-t", "upgrade", "-d", old],
               stderr_to_stdout: true
             )

    assert status != 0 and output =~ "reprovision over MaskROM"
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
          for name <- Flash.board().boot_files do
            path = Path.join(images, name)

            case name do
              "em300-parameter.txt" -> :ok
              "em300-idblock.img" -> File.write!(path, "RKNS" <> :binary.copy(<<0xAB>>, 208_892))
              _ -> File.write!(path, name)
            end

            "#{sha256(File.read!(path))}  #{name}\n"
          end

        File.write!(Path.join(images, "bootloader.sha256"), hashes)
        staged = Flash.prepare!(firmware, images, 0x100000, Path.join(tmp, "staged"))

        assert_raise Mix.Error, ~r/Unsupported NAND capacity/, fn ->
          Flash.prepare!(firmware, images, 0x80000, Path.join(tmp, "small"))
        end

        assert Enum.map(staged.writes, &elem(&1, 0)) == [
                 "idblock",
                 "uboot",
                 "ubi",
                 "env"
               ]

        {_, copies_path} = List.keyfind!(staged.writes, "idblock", 0)
        copies = File.read!(copies_path)
        assert byte_size(copies) == 4 * 128 * 1024
        assert binary_part(copies, 0, 262_144) == binary_part(copies, 262_144, 262_144)

        assert binary_part(copies, 0, 208_896) ==
                 File.read!(Path.join(images, "em300-idblock.img"))

        assert binary_part(copies, 208_896, 53_248) == :binary.copy(<<0xFF>>, 53_248)
        assert File.read!(Path.join(tmp, "staged/manifest.txt")) =~ "idblock sector=256"

        # Exercise the command contract without accessing USB. Both IDB copies
        # must be read back, after GPT, before any later partition is written.
        run = fn args ->
          send(self(), {:command, args})

          case args do
            ["rl", "256", "1024", path] ->
              File.write!(path, copies)

            ["rl", _, _, path] ->
              name = Path.basename(path, "-readback.bin")
              {_, source} = List.keyfind!(staged.writes, name, 0)
              data = File.read!(source)

              File.write!(
                path,
                data <> :binary.copy(<<0>>, rem(512 - rem(byte_size(data), 512), 512))
              )

            _ ->
              :ok
          end
        end

        Flash.install!(run, staged, 0x100000, Path.join(tmp, "staged"), backup: false)
        assert_receive {:command, ["ef"]}
        assert_receive {:command, ["gpt", _]}
        assert_receive {:command, ["wl", "256", ^copies_path]}
        assert_receive {:command, ["rl", "256", "1024", _]}
        refute_receive {:command, ["ul", _]}, 0

        corrupt = fn
          ["rl", "256", "1024", path] -> File.write!(path, :binary.copy(<<0>>, byte_size(copies)))
          ["wlx" | _] -> flunk("must stop before partition writes after IDB mismatch")
          _ -> :ok
        end

        assert_raise Mix.Error, ~r/Readback mismatch: idblock/, fn ->
          Flash.install!(corrupt, staged, 0x100000, Path.join(tmp, "staged"), backup: false)
        end

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

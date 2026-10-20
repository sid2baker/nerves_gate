defmodule EC100FlashTest do
  use ExUnit.Case, async: true
  alias Mix.Tasks.Ec100.Flash

  test "only factory regions are planned; payload sizes round up to sectors" do
    plan =
      Mix.Tasks.Ec100.Flash.regions!(
        %{"data/ec100.itb" => 513, "data/rootfs.img" => 1024},
        7_471_104
      )

    assert {"fit-a", 32768, 2} in plan
    assert {"rootfs-a", 163_840, 2} in plan
    assert {"initialize-data", 1_212_416, 256} in plan

    assert Enum.filter(plan, fn {_, sector, _} -> sector < 32768 end) ==
             [{"gpt-primary", 0, 34}, {"env-a", 24576, 256}, {"env-b", 24832, 256}]

    assert {"gpt-backup", 7_471_071, 33} in plan
  end

  test "factory boot area places SPL at LBA64 and U-Boot at LBA16384, below env" do
    boot = Flash.boot_area!(<<1, 2, 3>>, <<4, 5, 6>>)
    assert byte_size(boot) == (24576 - 64) * 512
    assert binary_part(boot, 0, 4) == <<1, 2, 3, 0>>
    assert binary_part(boot, (16384 - 64) * 512, 4) == <<4, 5, 6, 0>>
    assert_raise Mix.Error, fn -> Flash.boot_area!(<<1>>, :binary.copy(<<0>>, 4_194_305)) end
    assert_raise Mix.Error, fn -> Flash.boot_area!(<<>>, <<1>>) end
  end

  test "missing and oversized payloads fail closed" do
    assert_raise Mix.Error, fn -> Mix.Tasks.Ec100.Flash.regions!(%{}, 7_471_104) end

    assert_raise Mix.Error, fn ->
      Mix.Tasks.Ec100.Flash.regions!(
        %{"data/ec100.itb" => 33_554_433, "data/rootfs.img" => 1024},
        7_471_104
      )
    end
  end

  test "real fwup complete task prepares GPT p1/p2/p3 without USB access" do
    tmp = Path.join(System.tmp_dir!(), "ec100-flash-test-#{System.unique_integer([:positive])}")
    images = Path.join(tmp, "images")
    File.mkdir_p!(images)
    on_exit(fn -> File.rm_rf!(tmp) end)
    File.write!(Path.join(images, "ec100.itb"), :binary.copy(<<0xAB>>, 1024))
    File.write!(Path.join(images, "rootfs.squashfs"), :binary.copy(<<0xCD>>, 1024))

    for name <- ["idbloader.img", "u-boot.itb"],
        do: File.write!(Path.join(images, name), <<1, 2, 3>>)

    hash = :crypto.hash(:sha256, <<1, 2, 3>>) |> Base.encode16(case: :lower)

    File.write!(
      Path.join(images, "bootloader.sha256"),
      "#{hash}  idbloader.img\n#{hash}  u-boot.itb\n"
    )

    firmware = Path.join(tmp, "test.fw")
    fwup = System.find_executable("fwup") || flunk("fwup required for factory integration test")

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
    destination = Path.join(tmp, "prepared")

    files = Flash.prepare!(firmware, images, 7_471_104, destination)
    assert {"boot-area", 64, 24512, Path.join(destination, "boot-area.bin")} in files

    assert {"gpt-primary", 0, 34, Path.join(destination, "gpt-primary.bin")} in files
    assert {"gpt-backup", 7_471_071, 33, Path.join(destination, "gpt-backup.bin")} in files

    files
    |> Enum.sort_by(fn {_, sector, _, _} -> sector end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.each(fn [{_, start, count, _}, {_, next, _, _}] ->
      assert start + count <= next
    end)

    assert File.read!(Path.join(destination, "fit-a.bin")) == :binary.copy(<<0xAB>>, 1024)
    assert File.read!(Path.join(destination, "rootfs-a.bin")) == :binary.copy(<<0xCD>>, 1024)

    assert File.read!(Path.join(destination, "initialize-data.bin")) ==
             :binary.copy(<<255>>, 131_072)

    primary = File.read!(Path.join(destination, "gpt-primary.bin"))
    backup = File.read!(Path.join(destination, "gpt-backup.bin"))
    assert :ok == Flash.validate_gpt!(primary, backup, 7_471_104)

    for {name, i} <- Enum.with_index(["rootfs-a", "rootfs-b", "data"]) do
      encoded = :unicode.characters_to_binary(name, :utf8, {:utf16, :little})
      assert binary_part(primary, 1024 + i * 128 + 56, byte_size(encoded)) == encoded
    end

    for sectors <- [2_261_026, 8_000_000] do
      other = destination <> "-#{sectors}"
      Flash.prepare!(firmware, images, sectors, other)

      assert :ok ==
               Flash.validate_gpt!(
                 File.read!(Path.join(other, "gpt-primary.bin")),
                 File.read!(Path.join(other, "gpt-backup.bin")),
                 sectors
               )
    end

    assert_raise Mix.Error, ~r/Unsupported eMMC capacity/, fn ->
      Flash.prepare!(firmware, images, 2_261_025, destination <> "-small")
    end

    # Exercise both fwup creation and application: escaped ${name} used to be
    # consumed on the second pass, leaving a bare `mmc read` and `bootm`.
    expected_env =
      File.read!("bootstrap/uboot.env")
      |> String.split("\n", trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))

    for name <- ["env-a.bin", "env-b.bin"] do
      <<_crc_and_flag::binary-size(5), data::binary>> = File.read!(Path.join(destination, name))
      entries = :binary.split(data, <<0>>, [:global])
      for entry <- expected_env, do: assert(entry in entries, "#{name} missing #{entry}")

      # Nerves.Runtime.Init formats the initially blank data partition after
      # Erlang starts. Do not replace it with a second early-boot formatter.
      for entry <- [
            "a.nerves_fw_application_part0_devpath=/dev/rootdisk0p3",
            "a.nerves_fw_application_part0_fstype=ext4",
            "a.nerves_fw_application_part0_target=/root"
          ],
          do: assert(entry in entries, "#{name} missing #{entry}")
    end

    image = Path.join(destination, "factory.img")

    {output, status} =
      System.cmd(fwup, ["-a", "-U", "-i", firmware, "-d", image, "-t", "upgrade.b"])

    assert status == 0, output

    File.open!(image, [:read, :binary], fn io ->
      assert {:ok, ^primary} = :file.pread(io, 0, 34 * 512)
      assert {:ok, ^backup} = :file.pread(io, 7_471_071 * 512, 33 * 512)
      assert {:ok, :binary.copy(<<0xCD>>, 1024)} == :file.pread(io, 688_128 * 512, 1024)
    end)

    # The standard reset only invalidates the filesystem header, even when
    # p3 is larger than the old fixed 512 MiB trim range. No hardware access.
    ops = Path.join(tmp, "ops.fw")
    {output, status} = System.cmd(fwup, ["-c", "-f", "fwup-ops.conf", "-o", ops])
    assert status == 0, output

    protected = [
      {0, 34 * 512},
      {64 * 512, 512},
      {16384 * 512, 512},
      {24576 * 512, 512 * 512},
      {32768 * 512, 1024},
      {98304 * 512, 1024},
      {163_840 * 512, 1024},
      {688_128 * 512, 1024},
      {7_471_071 * 512, 33 * 512}
    ]

    File.open!(image, [:read, :write, :binary], fn io ->
      before = for {offset, size} <- protected, do: :file.pread(io, offset, size)
      data_start = 1_212_416 * 512
      untouched = [data_start + 131_072, data_start + 536_870_912, 7_471_070 * 512]
      sentinel = :binary.copy(<<0x5A>>, 512)
      :ok = :file.pwrite(io, data_start, sentinel)
      for offset <- untouched, do: :ok = :file.pwrite(io, offset, sentinel)
      :ok = :file.sync(io)

      {output, status} =
        System.cmd(fwup, [
          "-a",
          "-U",
          "--enable-trim",
          "-i",
          ops,
          "-d",
          image,
          "-t",
          "factory-reset"
        ])

      assert status == 0, output
      assert :file.pread(io, data_start, 131_072) == {:ok, :binary.copy(<<255>>, 131_072)}
      for offset <- untouched, do: assert(:file.pread(io, offset, 512) == {:ok, sentinel})
      assert before == for({offset, size} <- protected, do: :file.pread(io, offset, size))
    end)

    assert_raise Mix.Error, ~r/Output already exists/, fn ->
      Flash.prepare!(firmware, images, 7_471_104, destination)
    end

    File.write!(Path.join(images, "u-boot.itb"), "corrupted")

    assert_raise Mix.Error, ~r/Bootloader checksum mismatch/, fn ->
      Flash.prepare!(firmware, images, 7_471_104, destination <> "-bad")
    end

    refute File.exists?(destination <> "-bad")
  end

  test "detects exactly one correct MASKROM device" do
    device = "DevNo=1 Vid=0x2207,Pid=0x350f,LocationID=105 Maskrom"
    assert Flash.device!(device <> "\n") == device

    for listing <- [
          "not found any devices!",
          device <> "\n" <> device,
          "DevNo=1 Vid=0x2207,Pid=0x1234 Maskrom",
          "DevNo=1 Vid=0x2207,Pid=0x350f Loader"
        ] do
      assert_raise Mix.Error, fn -> Flash.device!(listing) end
    end
  end

  test "install backs up first, verifies writes, and writes primary GPT last" do
    tmp = Path.join(System.tmp_dir!(), "ec100-install-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    payload = Path.join(tmp, "payload")
    File.write!(payload, :binary.copy(<<7>>, 512))

    run = fn args ->
      send(self(), {:command, args})

      case args do
        ["rl", "0", "10", path] -> File.write!(path, :binary.copy(<<0>>, 5120))
        ["rl", _, "1", path] -> File.cp!(payload, path)
        ["wl", _, _] -> :ok
      end

      "OK"
    end

    files = [
      {"gpt-primary", 0, 1, payload},
      {"gpt-backup", 9, 1, payload},
      {"fit-a", 3, 1, payload}
    ]

    Flash.install!(run, files, 10, tmp)
    backup = Path.join(tmp, "emmc-before.img")

    for expected <- [
          ["rl", "0", "10", backup],
          ["wl", "3", payload],
          ["rl", "3", "1", Path.join(tmp, "fit-a-readback.bin")],
          ["wl", "9", payload],
          ["rl", "9", "1", Path.join(tmp, "gpt-backup-readback.bin")],
          ["wl", "0", payload],
          ["rl", "0", "1", Path.join(tmp, "gpt-primary-readback.bin")]
        ] do
      assert_receive {:command, actual}
      assert actual == expected
    end

    assert File.exists?(backup <> ".sha256")

    bad_readback = fn
      ["rl", "0", "10", path] -> File.write!(path, :binary.copy(<<0>>, 5120))
      ["rl", _, "1", path] -> File.write!(path, :binary.copy(<<0>>, 512))
      ["wl", sector, _] -> send(self(), {:write, sector})
    end

    assert_raise Mix.Error, ~r/Readback mismatch/, fn ->
      Flash.install!(bad_readback, files, 10, tmp)
    end

    assert_receive {:write, "3"}
    refute_receive {:write, "9"}
    refute_receive {:write, "0"}
    bad_backup = fn ["rl", "0", "10", path] -> File.write!(path, <<0>>) end

    assert_raise Mix.Error, ~r/Incomplete backup/, fn ->
      Flash.install!(bad_backup, files, 10, tmp)
    end
  end

  test "backup can be skipped without skipping readback verification" do
    tmp = Path.join(System.tmp_dir!(), "ec100-no-backup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf!(tmp) end)
    payload = Path.join(tmp, "payload")
    File.write!(payload, :binary.copy(<<7>>, 512))
    files = [{"fit-a", 3, 1, payload}]

    # No full-device read clause: attempting a backup fails this test.
    run = fn
      ["wl", "3", ^payload] ->
        send(self(), :written)

      ["rl", "3", "1", path] ->
        send(self(), :verified)
        File.cp!(payload, path)
    end

    Flash.install!(run, files, 10, tmp, backup: false)
    assert_receive :written
    assert_receive :verified
    refute File.exists?(Path.join(tmp, "emmc-before.img"))
    refute File.exists?(Path.join(tmp, "emmc-before.img.sha256"))

    bad_readback = fn
      ["wl", "3", ^payload] -> :ok
      ["rl", "3", "1", path] -> File.write!(path, :binary.copy(<<0>>, 512))
    end

    assert_raise Mix.Error, ~r/Readback mismatch/, fn ->
      Flash.install!(bad_readback, files, 10, tmp, backup: false)
    end
  end

  test "GPT rejects invalid headers, checksums, partitions, and capacity" do
    sectors = 7_471_104

    entries =
      for {start, last} <- [{163_840, 688_127}, {688_128, 1_212_415}, {1_212_416, sectors - 35}] do
        type = Base.decode16!("AF3DC60F838472478E793D69D8477DE4")
        <<type::binary, start::128, start::little-64, last::little-64, 0::640>>
      end
      |> IO.iodata_to_binary()
      |> Kernel.<>(:binary.copy(<<0>>, 16000))

    {primary, backup} = gpt_copies(entries, sectors)
    assert :ok == Flash.validate_gpt!(primary, backup, sectors)
    assert_raise Mix.Error, fn -> Flash.validate_gpt!(primary, backup, sectors + 1) end
    assert_raise Mix.Error, fn -> Flash.validate_gpt!(<<>>, backup, sectors) end

    for {copy, offset} <- [
          primary: 450,
          primary: 512,
          primary: 528,
          primary: 1024,
          backup: 0,
          backup: 16384,
          backup: 16400
        ] do
      original =
        if copy == :primary do
          primary
        else
          backup
        end

      corrupted = flip_byte(original, offset)

      assert_raise Mix.Error, fn ->
        if copy == :primary do
          Flash.validate_gpt!(corrupted, backup, sectors)
        else
          Flash.validate_gpt!(primary, corrupted, sectors)
        end
      end
    end

    {_, different_backup} = gpt_copies(flip_byte(entries, 56), sectors)

    assert_raise Mix.Error, ~r/GPT copies do not match/, fn ->
      Flash.validate_gpt!(primary, different_backup, sectors)
    end

    # Valid CRCs exercise the layout checks, not just corruption detection.
    for offset <- [0, 32, 40, 384] do
      altered = flip_byte(entries, offset)
      {bad_primary, bad_backup} = gpt_copies(altered, sectors)
      assert_raise Mix.Error, fn -> Flash.validate_gpt!(bad_primary, bad_backup, sectors) end
    end
  end

  defp flip_byte(binary, offset) do
    binary
    |> :binary.bin_to_list()
    |> List.update_at(offset, &Bitwise.bxor(&1, 1))
    |> :binary.list_to_bin()
  end

  defp gpt_copies(entries, sectors) do
    header = fn current, backup, table ->
      data =
        <<"EFI PART", 65536::little-32, 92::little-32, 0::64, current::little-64,
          backup::little-64, 34::little-64, sectors - 34::little-64, 1::128, table::little-64,
          128::little-32, 128::little-32, :erlang.crc32(entries)::little-32>>

      <<prefix::binary-size(16), _::32, suffix::binary>> = data
      <<prefix::binary, :erlang.crc32(data)::little-32, suffix::binary, 0::3360>>
    end

    mbr = <<0::3568, 0::32, 238, 0::24, 1::little-32, sectors - 1::little-32, 0::384, 85, 170>>

    {mbr <> header.(1, sectors - 1, 2) <> entries,
     entries <> header.(sectors - 1, 1, sectors - 33)}
  end
end

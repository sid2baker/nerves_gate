defmodule Workbench.FactoryProvisioningTest do
  use ExUnit.Case, async: true
  alias Workbench.FactoryProvisioning, as: Factory

  @maskrom "DevNo=1 Vid=0x2207,Pid=0x350f,LocationID=101 Maskrom\n"
  @loader "DevNo=1 Vid=0x2207,Pid=0x350f,LocationID=101 Loader\n"
  @flash_info "Flash Info:\n\tFlash Size: 7471104 Sectors\n"

  defp ec100, do: Factory.board!("ec100")
  defp em300, do: Factory.board!("em300")

  test "bulk reads and both write commands share a bounded thirty-minute timeout" do
    for args <- [
          ["rl", "0", "1048576", "backup.img"],
          ["wl", "8192", "uboot.img"],
          ["wlx", "ubi", "ubi.img"]
        ] do
      assert Factory.command_timeout(args) == 1_800_000
    end

    for operation <- ["ld", "rfi", "db", "ef", "ul", "gpt", "rd"] do
      assert Factory.command_timeout([operation]) == 30_000
    end
  end

  test "working RAM transport may retain the Maskrom label; identity brackets flash-info" do
    for listing <- [@maskrom, @loader] do
      run = fn command ->
        send(self(), {:command, command})

        case command do
          ["ld"] -> listing
          ["rfi"] -> @flash_info
        end
      end

      assert Factory.transport!(run, ec100(), "101") == 7_471_104
      assert_receive {:command, ["ld"]}
      assert_receive {:command, ["rfi"]}
      assert_receive {:command, ["ld"]}
      refute_receive {:command, _}, 0
      assert Factory.transport!(run, ec100(), "101", 7_471_104) == 7_471_104
      assert_receive {:command, ["ld"]}
      assert_receive {:command, ["rfi"]}
      assert_receive {:command, ["ld"]}
    end
  end

  test "Maskrom label alone never proves transport readiness" do
    for result <- ["", "Flash Size: 100 Sectors", "Flash Size: 4 GB", "Read Flash Info failed"] do
      run = fn
        ["ld"] -> @maskrom
        ["rfi"] -> result
      end

      assert_raise RuntimeError, fn -> Factory.transport!(run, ec100(), "101") end
    end

    run = fn
      ["ld"] -> @maskrom
      ["rfi"] -> raise "USB command failed"
    end

    assert_raise RuntimeError, ~r/USB command failed/, fn ->
      Factory.transport!(run, ec100(), "101")
    end
  end

  test "transport refuses ambiguous, unsupported or relocated devices before querying capacity" do
    for listing <- [
          "",
          @maskrom <> @loader,
          String.replace(@maskrom, "350f", "350a"),
          String.replace(@maskrom, "2207", "1234"),
          String.replace(@maskrom, "101", "102"),
          String.replace(@maskrom, "Maskrom", "Unknown")
        ] do
      run = fn
        ["ld"] -> listing
        command -> flunk("must not query or write an unverified device: #{inspect(command)}")
      end

      assert_raise ArgumentError, fn -> Factory.transport!(run, ec100(), "101") end
    end
  end

  test "device disappearing or moving during flash-info invalidates transport" do
    for after_info <- ["", String.replace(@maskrom, "101", "102"), @maskrom <> @loader] do
      run = fn
        ["ld"] ->
          receive do
            :flash_info_read -> after_info
          after
            0 -> @maskrom
          end

        ["rfi"] ->
          send(self(), :flash_info_read)
          @flash_info
      end

      assert_raise ArgumentError, fn -> Factory.transport!(run, ec100(), "101") end
    end
  end

  test "successful flash-info with changed capacity does not authorize a write or reset" do
    run = fn
      ["ld"] -> @maskrom
      ["rfi"] -> @flash_info
    end

    assert_raise ArgumentError, ~r/Device capacity changed; no write or reset authorized/, fn ->
      Factory.transport!(run, ec100(), "101", 7_471_105)
    end
  end

  test "only one matching controller, mode and reviewed USB location is admitted" do
    assert Factory.device!(@maskrom, "Maskrom") == "101"
    assert Factory.device!(@loader, "Loader", "101") == "101"

    for {listing, mode, location} <- [
          {"", "Maskrom", nil},
          {@maskrom <> @maskrom, "Maskrom", nil},
          {String.replace(@maskrom, "350f", "350a"), "Maskrom", nil},
          {String.replace(@maskrom, "2207", "1234"), "Maskrom", nil},
          {@maskrom, "Loader", nil},
          {@loader, "Maskrom", nil},
          {@loader, "Loader", "102"}
        ] do
      assert_raise ArgumentError, fn -> Factory.device!(listing, mode, location) end
    end
  end

  test "capacity and conservative disk budget reject unsafe preparation" do
    assert Factory.capacity!("Flash Size: 7471104 Sectors", ec100()) == 7_471_104
    assert_raise RuntimeError, fn -> Factory.capacity!("Flash Size: 100 Sectors", ec100()) end

    assert_raise RuntimeError, fn ->
      Factory.capacity!("Flash Size: 4294967296 Sectors", ec100())
    end

    assert_raise RuntimeError, fn -> Factory.capacity!("Flash Size: 4GB", ec100()) end

    # EM300: exactly the 512 MiB SPI NAND whose layout ends at 0x1FF00000.
    assert Factory.capacity!("Flash Size: 1048576 Sectors", em300()) == 1_048_576

    for sectors <- [1_046_527, 2_097_152, 7_471_104] do
      assert_raise RuntimeError, ~r/Unsupported EM300 SPI NAND capacity/, fn ->
        Factory.capacity!("Flash Size: #{sectors} Sectors", em300())
      end
    end

    # An eMMC-sized device never passes as an EM300, nor a NAND-sized one as EC100.
    assert_raise RuntimeError, fn -> Factory.capacity!("Flash Size: 1048576 Sectors", ec100()) end
    required = Factory.required_space(7_471_104, 50_000_000)
    assert required > 7_471_104 * 512 * 3
    assert Factory.space!(required, required) == :ok

    assert_raise ArgumentError, ~r/Insufficient factory disk space/, fn ->
      Factory.space!(required - 1, required)
    end
  end

  test "backup is enabled by default and can only be explicitly skipped" do
    assert Factory.backup_enabled!(nil)
    assert Factory.backup_enabled!("true")
    refute Factory.backup_enabled!("false")

    for value <- [false, true, "", "skip", [], %{}] do
      assert_raise ArgumentError, fn -> Factory.backup_enabled!(value) end
    end

    sectors = 7_471_104
    full = Factory.required_space(sectors, 50_000_000)
    skipped = Factory.required_space(sectors, 50_000_000, false)
    assert full - skipped == sectors * 512
    assert skipped > sectors * 512 * 2
    assert Factory.erase_confirmation(ec100(), "101", true) == "ERASE EC100 101"
    assert Factory.erase_confirmation(ec100(), "101", false) == "ERASE EC100 101 WITHOUT BACKUP"
    assert Factory.erase_confirmation(em300(), "101", true) == "ERASE EM300 101"
  end

  test "skipping backup is bound into the reviewed erase phrase" do
    plan = %{
      public: %{
        kind: :factory,
        token: "token",
        backup_enabled: false,
        confirmation: Factory.erase_confirmation(ec100(), "101", false)
      },
      expires: System.monotonic_time(:millisecond) + 60_000
    }

    assert_raise ArgumentError, ~r/exact erase confirmation/, fn ->
      Factory.confirmation!(plan, "token", "ERASE EC100 101", "true")
    end

    assert Factory.confirmation!(plan, "token", "ERASE EC100 101 WITHOUT BACKUP", "true") == :ok
  end

  test "firmware must match a physical board's product and architecture" do
    image = %{
      "meta-platform" => "ec100",
      "meta-architecture" => "arm",
      "meta-product" => "nerves_gate",
      "meta-version" => "0.2.0-dev"
    }

    assert Factory.compatible!(image) == "ec100"
    assert Factory.compatible!(%{image | "meta-platform" => "em300"}) == "em300"

    for key <- Map.keys(image) do
      assert_raise ArgumentError, fn -> Factory.compatible!(Map.delete(image, key)) end
    end

    for {key, value} <- [
          {"meta-platform", "x86_64"},
          {"meta-platform", "ec100_qemu"},
          {"meta-architecture", "x86_64"},
          {"meta-product", "other"}
        ] do
      assert_raise ArgumentError, fn -> Factory.compatible!(Map.put(image, key, value)) end
    end
  end

  test "confirmation binds token, expiry, erase phrase and physical identification" do
    plan = %{
      public: %{kind: :factory, token: "token", board: "EC100", confirmation: "ERASE EC100 101"},
      expires: System.monotonic_time(:millisecond) + 60_000
    }

    assert Factory.confirmation!(plan, "token", "ERASE EC100 101", "true") == :ok

    for {token, text, identified} <- [
          {nil, "ERASE EC100 101", "true"},
          {"other", "ERASE EC100 101", "true"},
          {"token", "ERASE EC100 102", "true"},
          {"token", "ERASE EC100 101", nil},
          {"token", "ERASE EC100 101", "false"}
        ] do
      assert_raise ArgumentError, fn -> Factory.confirmation!(plan, token, text, identified) end
    end

    assert_raise ArgumentError, ~r/expired/, fn ->
      Factory.confirmation!(
        %{plan | expires: System.monotonic_time(:millisecond) - 1},
        "token",
        "ERASE EC100 101",
        "true"
      )
    end
  end

  @tag :tmp_dir
  test "RAM download only receives an existing, readable, hash-verified staged loader", %{
    tmp_dir: dir
  } do
    board = em300()
    path = Path.join(dir, board.loader)
    bytes = "reviewed loader"
    hash = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    assert_raise RuntimeError, ~r/No USB download was attempted/, fn ->
      Factory.loader!(dir, board, hash)
    end

    File.write!(path, bytes)
    File.chmod!(path, 0o400)
    assert Factory.loader!(dir, board, hash) == path

    File.chmod!(path, 0o600)

    for contents <- ["", "different loader"] do
      File.write!(path, contents)

      assert_raise RuntimeError, ~r/missing, unreadable or changed/, fn ->
        Factory.loader!(dir, board, hash)
      end
    end

    File.rm!(path)
    File.mkdir!(path)

    assert_raise RuntimeError, ~r/No USB download was attempted/, fn ->
      Factory.loader!(dir, board, hash)
    end
  end

  test "RAM transport progress does not expose an expiring command for manual replay" do
    label = Factory.command_label(["db", "/temporary/factory-reviews/review/loader.bin"])
    assert label =~ "RAM transport"
    assert label =~ "no flash writes"
    refute label =~ "/temporary"
    refute label =~ "rkdeveloptool db"
    assert Factory.command_label(["rfi"]) == "rkdeveloptool rfi"
  end

  test "USB-open failure is distinct from loader-open failure and explains explicit access choices" do
    output = "\e[30;41mCreating Comm Object failed!\e[0m\r\n"
    error = Factory.command_error(["db", "/temporary/loader.bin"], output, 1, false)
    assert error =~ "RAM loader opened"
    assert error =~ "could not open or claim"
    assert error =~ "udev"
    assert error =~ "explicitly select Noninteractive sudo"
    assert error =~ "ld does not prove download access"
    assert error =~ "No automatic retry"
    refute error =~ "\e["
    refute error =~ "/temporary"

    sudo_error = Factory.command_error(["db", "/temporary/loader.bin"], output, 1, true)
    assert sudo_error =~ "sudo -n is authorized"
    assert sudo_error =~ "workbench process"
    refute sudo_error =~ "explicitly select"

    file_error =
      Factory.command_error(["db", "/temporary/loader.bin"], "Opening loader failed", 1, false)

    assert file_error =~ "could not read or parse"
    refute file_error =~ "RAM loader opened"
    refute file_error =~ "udev"
  end

  test "other USB errors remain bounded and never authorize automatic retry" do
    error = Factory.command_error(["wl", "0", "image"], String.duplicate("x", 1000), 5, false)
    assert error =~ "USB command failed (5)"
    refute error =~ String.duplicate("x", 501)
    assert error =~ "No automatic retry"
    assert error =~ "Inspect the device"
  end

  @tag :tmp_dir
  test "review cleanup never removes backups or readbacks", %{tmp_dir: dir} do
    snapshot = Path.join(dir, "review")
    backup = Path.join(dir, "backup")
    File.mkdir!(snapshot)
    File.mkdir!(backup)
    File.write!(Path.join(backup, "emmc-before.img"), "preserve")
    Factory.cleanup(%{dir: snapshot, public: %{backup: backup}})
    refute File.exists?(snapshot)
    assert File.read!(Path.join(backup, "emmc-before.img")) == "preserve"
  end

  test "each board's system flash task provides the staging and verified-write engine" do
    for platform <- Workbench.Builds.physical_targets() do
      %{engine: module, name: name, loader: loader, boot_files: files, sectors: %Range{}} =
        Factory.board!(platform)

      assert name == String.upcase(platform)
      assert function_exported?(module, :prepare!, 4)
      assert function_exported?(module, :install!, 5)
      assert loader in files
    end

    assert_raise ArgumentError, fn -> Factory.board!("x86_64") end
  end
end

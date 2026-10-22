defmodule Dev.FactoryProvisioningTest do
  use ExUnit.Case, async: true
  alias Dev.FactoryProvisioning, as: Factory

  @maskrom "DevNo=1 Vid=0x2207,Pid=0x350f,LocationID=101 Maskrom\n"
  @loader "DevNo=1 Vid=0x2207,Pid=0x350f,LocationID=101 Loader\n"

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
    assert Factory.capacity!("Flash Size: 7471104 Sectors") == 7_471_104
    assert_raise RuntimeError, fn -> Factory.capacity!("Flash Size: 100 Sectors") end
    assert_raise RuntimeError, fn -> Factory.capacity!("Flash Size: 4294967296 Sectors") end
    assert_raise RuntimeError, fn -> Factory.capacity!("Flash Size: 4GB") end
    required = Factory.required_space(7_471_104, 50_000_000)
    assert required > 7_471_104 * 512 * 3
    assert Factory.space!(required, required) == :ok

    assert_raise ArgumentError, ~r/Insufficient backup disk space/, fn ->
      Factory.space!(required - 1, required)
    end
  end

  test "firmware must match the physical EC100 product and architecture" do
    image = %{
      "meta-platform" => "ec100",
      "meta-architecture" => "arm",
      "meta-product" => "nerves_gate",
      "meta-version" => "0.2.0-dev"
    }

    assert Factory.compatible!(image) == :ok

    for key <- Map.keys(image) do
      assert_raise ArgumentError, fn -> Factory.compatible!(Map.delete(image, key)) end
    end

    for {key, value} <- [
          {"meta-platform", "x86_64"},
          {"meta-architecture", "x86_64"},
          {"meta-product", "other"}
        ] do
      assert_raise ArgumentError, fn -> Factory.compatible!(Map.put(image, key, value)) end
    end
  end

  test "confirmation binds token, expiry, erase phrase and physical identification" do
    plan = %{
      public: %{kind: :factory, token: "token", confirmation: "ERASE EC100 101"},
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
end

defmodule Workbench.AppInstallTest do
  use ExUnit.Case, async: true
  alias Workbench.AppInstall

  test "new physical installs require prepared storage, compatible SDK/platform and identity" do
    device = %{
      product: "nerves_gate",
      target: "ec100",
      serial: "serial",
      boot_id: "boot",
      storage_ready: true,
      card_id: "card",
      installed: false,
      platform_compatible: true,
      sdk_version: "0.2.0-dev"
    }

    assert :ok = AppInstall.compatible!(device, "~> 0.2.0-dev")

    for changed <- [
          %{device | installed: true},
          %{device | storage_ready: false},
          %{device | platform_compatible: false},
          %{device | serial: ""},
          %{device | sdk_version: "0.1.0"},
          %{device | product: "other"}
        ] do
      assert_raise ArgumentError, fn -> AppInstall.compatible!(changed, "~> 0.2.0-dev") end
    end
  end

  test "no install or firmware upload is entered without exact unexpired confirmation" do
    plan = %{
      public: %{token: "review", address: "gateway.example"},
      expires: System.monotonic_time(:millisecond) + 10_000
    }

    assert :ok = AppInstall.confirmation!(plan, "review", "gateway.example")
    assert_raise ArgumentError, fn -> AppInstall.confirmation!(plan, "review", "other") end

    assert_raise ArgumentError, fn ->
      AppInstall.confirmation!(
        %{plan | expires: System.monotonic_time(:millisecond) - 1},
        "review",
        "gateway.example"
      )
    end

    # No snapshot or remote target is supplied: rejection must precede all effects.
    assert_raise ArgumentError, fn ->
      AppInstall.install!(plan, "wrong", "gateway.example", fn _ -> :ok end)
    end

    assert_raise ArgumentError, fn ->
      Workbench.FirmwareUpdate.update!(plan, "wrong", "gateway.example")
    end
  end
end

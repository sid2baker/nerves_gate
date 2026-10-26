defmodule Workbench.HardwareTest do
  use ExUnit.Case, async: true
  alias Workbench.FirmwareUpdate

  test "readiness requires verified SSH, not an independent USB connection" do
    scenario = Scenarios.describe(Scenarios.Cases.HardwareReadiness)
    assert scenario.opt_in
    assert scenario.requires.fixture == [:ssh_management]

    assert Scenarios.Device.fixture_capabilities(%{management: :verified_ssh}) == [
             :ssh_management
           ]

    refute :usb_management in Scenarios.Device.fixture_capabilities(%{management: :verified_ssh})
    assert scenario in Scenarios.all()
    assert %{status: :skipped} = Scenarios.run(scenario, %{device: %{}})

    assert {:error, :unsupported_fixture_control} =
             Scenarios.Device.control(%{management: :verified_usb}, :usb_management)
  end

  test "read-only profile assertions distinguish readiness from a failover exercise" do
    for profile <- Workbench.Hardware.profiles() do
      snapshot = snapshot(profile)
      assert %{status: :passed} = check(profile, snapshot)
      assert %{status: :failed} = check(profile, %{snapshot | "pending" => true})
      assert %{status: :failed} = check(profile, %{snapshot | "recovering" => true})

      assert %{status: :failed} =
               check(profile, put_in(snapshot, ["internet", "health"], "unverified"))
    end

    backup = snapshot("backup")

    assert %{status: :failed} =
             check("backup", put_in(backup, ["internet", "selected"], "cellular"))

    assert %{status: :failed} =
             check("backup", put_in(backup, ["internet", "cellular"], "disconnected"))

    assert %{status: :failed} = check("backup", put_in(backup, ["cellular", "present"], false))

    assert %{status: :failed} =
             check("cellular", put_in(snapshot("cellular"), ["cellular", "sim"], "pin_required"))
  end

  test "readiness failures explain profile mismatches and pending trials without developer stack traces" do
    assert %{status: :failed, detail: detail} = check("ethernet", snapshot("backup"))
    assert detail =~ "Expected Ethernet-only"
    assert detail =~ "gateway reports backup"
    refute detail =~ "ExUnit.AssertionError"
    refute detail =~ ".ex:"
    snapshot = snapshot("backup") |> Map.put("pending", true) |> Map.put("ready", false)
    assert %{status: :failed, detail: detail} = check("backup", snapshot)
    assert detail =~ "active network trial"
  end

  test "USB SSH options bind both the interface and source without relaxing host authentication" do
    options =
      Workbench.DeviceSSH.options("172.31.211.1", %{local: {172, 31, 211, 2}, interface: "enxusb"})

    assert options[:ip] == {172, 31, 211, 2}
    assert options[:bind_to_device] == "enxusb"
    assert options[:silently_accept_hosts] == false
    assert options[:save_accepted_host] == false
    assert options[:user_interaction] == false
    assert options[:auth_methods] == ~c"publickey"
  end

  test "hardware reads use a static, valid Elixir command and retain only public observations" do
    command = Workbench.DeviceSSH.hardware_command()
    assert {:ok, _} = Code.string_to_quoted(command)
    assert command == Workbench.DeviceSSH.command(NervesGate.System, :hardware_info)
    refute command =~ "ready: s.network.ready"

    data =
      snapshot("backup")
      |> Map.put("private_key", "private")
      |> put_in(["cellular", "iccid"], "private")

    public = Workbench.DeviceSSH.hardware_snapshot!(data)
    refute inspect(public) =~ "private"
    assert public["internet"]["mode"] == "backup"
    assert_raise RuntimeError, fn -> Workbench.DeviceSSH.hardware_snapshot!(%{}) end
  end

  test "update verification requires the same device, reviewed version and a different boot" do
    revision = String.duplicate("a", 40)
    before_update = snapshot("backup") |> Map.put("source_revision", revision)
    observed = Map.put(before_update, "boot_id", "00000000-0000-0000-0000-000000000002")
    assert FirmwareUpdate.same_reviewed_boot?(before_update, before_update)
    refute FirmwareUpdate.same_reviewed_boot?(before_update, observed)
    assert FirmwareUpdate.verified_update?(before_update, observed, "new", revision)
    refute FirmwareUpdate.verified_update?(before_update, before_update, "new", revision)

    refute FirmwareUpdate.verified_update?(
             before_update,
             Map.delete(observed, "source_revision"),
             "new",
             revision
           )

    refute FirmwareUpdate.verified_update?(before_update, observed, "new", nil)
    refute FirmwareUpdate.verified_update?(before_update, observed, "new", "different")

    for altered <- [
          Map.put(observed, "version", "old"),
          Map.put(observed, "serial", "another"),
          Map.put(observed, "ready", false),
          Map.put(observed, "firmware_validated", false),
          Map.put(observed, "pending", true),
          Map.put(observed, "recovering", true)
        ] do
      refute FirmwareUpdate.verified_update?(before_update, altered, "new", revision)
    end
  end

  test "assisted failover requires explicit consent and USB plus operator fixture capabilities" do
    scenario = Scenarios.describe(Scenarios.Cases.HardwareBackup)
    assert scenario.opt_in
    assert scenario in Scenarios.all()
    assert %{status: :skipped} = Scenarios.run(scenario, %{device: %{management: :verified_usb}})

    assert %{status: :skipped} =
             Scenarios.run(scenario, %{
               device: %{management: :verified_ssh, manual_ethernet: true}
             })

    assert_raise ArgumentError, ~r/authorize/, fn ->
      Workbench.Hardware.failover!("anything", "false", fn _ -> flunk("must not prompt") end)
    end

    assert {:error, :unsupported_fixture_control} =
             Scenarios.Device.control(
               %{management: :verified_usb, manual_ethernet: true},
               :manual_ethernet
             )
  end

  test "failover phases require physical link transitions as well as connectivity and source preference" do
    baseline = put_in(snapshot("backup"), ["internet", "ethernet_link"], true)
    refute Scenarios.Cases.HardwareBackup.phase?(:takeover, baseline)

    takeover =
      baseline
      |> put_in(["internet", "selected"], "cellular")
      |> put_in(["internet", "ethernet_link"], false)

    assert Scenarios.Cases.HardwareBackup.phase?(:takeover, takeover)
    refute Scenarios.Cases.HardwareBackup.phase?(:return, takeover)

    refute Scenarios.Cases.HardwareBackup.phase?(
             :takeover,
             put_in(takeover, ["internet", "ethernet_link"], true)
           )

    refute Scenarios.Cases.HardwareBackup.phase?(
             :takeover,
             put_in(takeover, ["internet", "cellular"], "lan")
           )

    assert Scenarios.Cases.HardwareBackup.phase?(:return, baseline)

    refute Scenarios.Cases.HardwareBackup.phase?(
             :return,
             put_in(baseline, ["internet", "cellular"], "disconnected")
           )

    refute Scenarios.Cases.HardwareBackup.phase?(
             :return,
             put_in(baseline, ["internet", "ethernet_link"], nil)
           )
  end

  test "diagnostics exclude settings, logs, SIM identifiers and credentials" do
    snapshot =
      snapshot("backup")
      |> Map.put("settings", "secret")
      |> Map.put("logs", "secret")
      |> put_in(["cellular", "iccid"], "secret")
      |> put_in(["cellular", "authentication"], "secret")

    report = Workbench.Hardware.diagnostic_report(snapshot, "usb0")
    assert report.management.endpoint == "usb0"
    assert report.device["serial"] == "device-42"
    assert {:ok, _, _} = DateTime.from_iso8601(report.observed_at)
    refute inspect(report) =~ "secret"
  end

  test "invalid verification modes are rejected before any device connection" do
    assert_raise ArgumentError, ~r/Choose SSH reconnect/, fn ->
      FirmwareUpdate.review!(%{"address" => "device.example", "verify_usb" => "unexpected"})
    end

    assert_raise ArgumentError, ~r/Choose verified SSH/, fn ->
      Workbench.Hardware.review_reboot!("device.example", "unexpected")
    end
  end

  test "reboot observation confirmation is typed, one review kind and time limited" do
    plan = %{
      public: %{kind: :reboot, token: "review", address: "172.31.211.1"},
      expires: System.monotonic_time(:millisecond) + 60_000
    }

    assert :ok = Workbench.Hardware.confirmation!(plan, "review", "172.31.211.1")

    for {token, address} <- [{"other", "172.31.211.1"}, {"review", "other"}] do
      assert_raise ArgumentError, fn ->
        Workbench.Hardware.confirmation!(plan, token, address)
      end
    end

    assert_raise ArgumentError, fn ->
      Workbench.Hardware.confirmation!(
        %{plan | expires: System.monotonic_time(:millisecond) - 1},
        "review",
        "172.31.211.1"
      )
    end
  end

  defp check(profile, snapshot),
    do:
      Scenarios.run(Scenarios.Cases.HardwareReadiness, %{
        device: %{management: :verified_ssh},
        snapshot: snapshot,
        profile: profile
      })

  defp snapshot(profile) do
    %{
      "target" => "ec100",
      "product" => "nerves_gate",
      "version" => "new",
      "source_revision" => String.duplicate("a", 40),
      "serial" => "device-42",
      "boot_id" => "00000000-0000-0000-0000-000000000001",
      "available" => true,
      "firmware_validated" => true,
      "ready" => true,
      "pending" => false,
      "recovering" => false,
      "internet" => %{
        "mode" => profile,
        "selected" => if(profile == "cellular", do: "cellular", else: "ethernet"),
        "ethernet" => "internet",
        "cellular" => "internet",
        "health" => "online"
      },
      "cellular" => %{"supported" => true, "present" => true, "enabled" => true, "sim" => "ready"}
    }
  end
end

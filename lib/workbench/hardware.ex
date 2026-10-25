defmodule Workbench.Hardware do
  @moduledoc "Verified-SSH checks and procedures; disruptive network tests require independent USB management."
  alias Workbench.{FactoryConnection, FirmwareUpdate}

  def profiles, do: ["ethernet", "cellular", "backup"]

  def discover! do
    devices =
      FactoryConnection.usb_paths()
      |> Enum.uniq()
      |> Enum.take(8)
      |> Enum.flat_map(fn path ->
        case FactoryConnection.probe(path, nil, 2_000) do
          {:ok, info} ->
            :ok = Workbench.LANDiscovery.record_usb(info)
            [info.address]

          _ ->
            []
        end
      end)

    if devices == [],
      do:
        raise(
          "No EC100 was found on an independent USB /30 management network. Connect USB, enable workstation DHCP on that interface and try again. No networking settings were changed."
        )

    "USB gateways added: " <> Enum.join(devices, ", ")
  end

  def diagnostics!(address) do
    snapshot = FirmwareUpdate.read_hardware!(address)
    :ok = Workbench.LANDiscovery.record_identity(address, snapshot)
    diagnostic_report(snapshot, address)
  end

  @doc false
  def diagnostic_report(snapshot, endpoint) do
    %{
      observed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      management: %{transport: "verified SSH", endpoint: endpoint},
      device: FirmwareUpdate.hardware_snapshot!(snapshot)
    }
  end

  def failover!(address, consent, report) do
    unless consent == "true",
      do:
        raise(
          ArgumentError,
          "Explicitly authorize cellular data use and manual Ethernet disconnection first"
        )

    peer = FactoryConnection.usb_peer!(address)
    snapshot = FirmwareUpdate.read_hardware!(peer)
    check_cancel!()

    result =
      Scenarios.run(Scenarios.Cases.HardwareBackup, %{
        device: %{management: :verified_usb, manual_ethernet: true},
        snapshot: snapshot,
        report: report,
        read_snapshot: fn ->
          check_cancel!()
          observed = FirmwareUpdate.read_hardware!(peer, 2_000)

          unless FirmwareUpdate.same_reviewed_boot?(snapshot, observed) and
                   observed["available"] == true,
                 do:
                   raise(
                     "Device identity, firmware or boot changed. Stop testing and restore Ethernet cables."
                   )

          observed
        end
      })

    :ok = FactoryConnection.verify_usb!(peer)

    %{
      profile: "backup failover · operator-assisted",
      rows: [Map.put(result, :id, "hardware_backup")]
    }
  end

  def review_reboot!(address, management \\ "ssh") do
    target =
      case management do
        "ssh" -> address
        "usb" -> FactoryConnection.usb_peer!(address)
        _ -> raise ArgumentError, "Choose verified SSH or independent USB management"
      end

    snapshot = FirmwareUpdate.read_hardware!(target)

    unless snapshot["available"] == true and snapshot["firmware_validated"] == true and
             snapshot["ready"] == true and snapshot["pending"] == false and
             snapshot["recovering"] == false,
           do:
             raise(
               "Wait for validated firmware and healthy network state, with no pending trial or recovery, before reviewing a reboot"
             )

    %{
      public: %{
        kind: :reboot,
        address: address,
        serial: snapshot["serial"],
        version: snapshot["version"],
        management: if(is_map(target), do: "USB · #{target.interface}", else: "SSH · #{address}"),
        token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)
      },
      management_target: target,
      before_reboot: snapshot,
      expires: System.monotonic_time(:millisecond) + 600_000
    }
  end

  def confirm_reboot!(plan, token, address) do
    unless plan.public.kind == :reboot and token == plan.public.token and
             address == plan.public.address and System.monotonic_time(:millisecond) < plan.expires,
           do:
             raise(
               ArgumentError,
               "Review the reboot again and type the exact reviewed address"
             )

    :ok
  end

  def observe_reboot!(plan, report) do
    :ok = confirm_reboot!(plan, plan.public.token, plan.public.address)
    current = FirmwareUpdate.read_hardware!(plan.management_target)
    check_cancel!()

    unless FirmwareUpdate.same_reviewed_boot?(plan.before_reboot, current),
      do:
        raise("Device rebooted or changed since review. Review again before pressing the button.")

    report.(
      "Reboot observation armed for three minutes. Short-press and release once to arm the physical button, then hold 5–10 seconds and release while RUN blinks slowly. Never hold for 30 seconds (factory reset). Do not repeat if the outcome is uncertain. Keep management access and power connected. No remote reboot command is sent."
    )

    poll_reboot(plan, report, System.monotonic_time(:millisecond) + 180_000)
  end

  defp poll_reboot(plan, report, until) do
    check_cancel!()

    if System.monotonic_time(:millisecond) >= until,
      do:
        raise(
          "Reboot verification incomplete: no matching healthy new boot over the reviewed management connection. Remote access may be unavailable. Inspect the device; do not repeat the button action automatically."
        )

    observed =
      try do
        FirmwareUpdate.read_hardware!(plan.management_target, 2_000)
      rescue
        _ -> nil
      end

    if observed &&
         (observed["serial"] != plan.before_reboot["serial"] or
            observed["version"] != plan.before_reboot["version"]),
       do:
         raise(
           "Device identity or firmware changed while observing reboot. Inspect the device; no reboot was repeated."
         )

    if observed &&
         FirmwareUpdate.verified_update?(plan.before_reboot, observed, plan.public.version) do
      :ok = Workbench.LANDiscovery.record_identity(plan.public.address, observed)

      report.(
        "Verified a different boot, unchanged identity/firmware and healthy validated state over authenticated SSH."
      )

      {:ok,
       "Physical-button reboot verified after reconnecting over authenticated SSH. The workbench sent no reboot or reset command."}
    else
      Process.sleep(1_000)
      poll_reboot(plan, report, until)
    end
  end

  defp check_cancel! do
    receive do
      :cancel_hardware_observation ->
        raise(
          "Observation cancelled. Restore Ethernet cables and inspect the device. No write or button action was retried."
        )
    after
      0 -> :ok
    end
  end

  def run!(address, profile) do
    unless profile in profiles(),
      do: raise(ArgumentError, "Choose Ethernet, 4G or Ethernet with 4G backup")

    snapshot = FirmwareUpdate.read_hardware!(address)

    result =
      Scenarios.run(Scenarios.Cases.HardwareReadiness, %{
        device: %{management: :verified_ssh},
        snapshot: snapshot,
        profile: profile
      })

    :ok = Workbench.LANDiscovery.record_identity(address, snapshot)

    %{
      profile: profile,
      observed:
        Map.take(snapshot["internet"], ["mode", "selected", "ethernet", "cellular", "health"]),
      rows: [Map.put(result, :id, "hardware_readiness")]
    }
  end
end

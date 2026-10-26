defmodule Workbench.FirmwareUpdate do
  @moduledoc "Explicit SSH firmware review/update; never provisions disks or bypasses host-key checks."
  @ttl 600_000

  def review!(params, report \\ fn _ -> :ok end) do
    {:ok, host} = Workbench.DeviceSSH.host!(params["address"])
    port = port!(params["port"] || 22)

    unless params["verify_usb"] in [nil, "false", "true", "ssh"],
      do:
        raise(
          ArgumentError,
          "Choose SSH reconnect verification, independent USB verification or manual verification"
        )

    usb = if params["verify_usb"] == "true", do: Workbench.FactoryConnection.usb_peer!(host)
    verify_ssh = params["verify_usb"] == "ssh"

    if (usb || verify_ssh) && port != 22,
      do: raise(ArgumentError, "Reconnect verification requires verified SSH on port 22")

    original = Path.expand(params["firmware"] || "")

    unless Path.extname(original) == ".fw" and File.regular?(original),
      do: raise(ArgumentError, "Select an existing .fw file or build firmware first")

    if File.stat!(original).size > 512 * 1024 * 1024,
      do: raise(ArgumentError, "Firmware archives must be no larger than 512 MiB")

    dir =
      Path.join(
        Workbench.root(),
        "_build/firmware-updates/#{Base.encode16(:crypto.strong_rand_bytes(16))}"
      )

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    snapshot = Path.join(dir, "image.fw")

    try do
      File.cp!(original, snapshot)
      File.chmod!(snapshot, 0o400)
      report.("Checking the firmware archive")
      image = image!(snapshot)
      report.("Verifying the device over authenticated SSH (read-only)")

      device =
        Workbench.DeviceSSH.with_connection(host, port, &Workbench.DeviceSSH.identity!/1, usb)

      compatible!(image, device)
      before_update = if usb || verify_ssh, do: Workbench.DeviceSSH.read_hardware!(usb || host)

      if before_update && before_update["serial"] != device["serial"],
        do: raise("Device identity changed during review")

      public = %{
        token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
        address: host,
        port: port,
        firmware: original,
        target: image["meta-platform"],
        architecture: image["meta-architecture"],
        current_version: device["version"],
        version: image["meta-version"],
        source_revision: image["meta-vcs-identifier"],
        serial: device["serial"],
        sha256: hash!(snapshot),
        verify_usb: not is_nil(usb),
        verify_ssh: verify_ssh,
        management: if(usb, do: usb.interface)
      }

      %{
        owner: __MODULE__,
        public: public,
        snapshot: snapshot,
        dir: dir,
        device: device,
        usb: usb,
        before_update: before_update,
        expires: System.monotonic_time(:millisecond) + @ttl
      }
    catch
      kind, reason ->
        File.rm_rf!(dir)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def confirmation!(plan, token, address) do
    cond do
      not is_binary(token) or token != plan.public.token ->
        raise ArgumentError, "Review the firmware before confirming"

      address != plan.public.address ->
        raise ArgumentError, "Type the exact reviewed hostname/address to confirm"

      System.monotonic_time(:millisecond) >= plan.expires ->
        raise ArgumentError, "Firmware review expired; review again"

      true ->
        :ok
    end
  end

  def update!(plan, report \\ fn _ -> :ok end) do
    try do
      confirmation!(plan, plan.public.token, plan.public.address)

      if hash!(plan.snapshot) != plan.public.sha256,
        do: raise("Reviewed firmware changed; review again")

      usb = plan[:usb]
      if usb, do: Workbench.FactoryConnection.verify_usb!(usb)

      Workbench.DeviceSSH.with_connection(
        plan.public.address,
        plan.public.port,
        fn connection ->
          # DNS or device state may have changed since review. Check again before
          # opening the fwup subsystem, which admits a device-side state change.
          if Workbench.DeviceSSH.identity!(connection) != plan.device,
            do: raise("Device identity/version changed; no firmware sent. Review again")

          if plan[:before_update] do
            current =
              Workbench.DeviceSSH.read!(connection, Workbench.DeviceSSH.hardware_command(), 5_000)
              |> Workbench.DeviceSSH.hardware_snapshot!()

            unless same_reviewed_boot?(plan.before_update, current),
              do:
                raise("Device rebooted or changed since review; no firmware sent. Review again.")

            if usb, do: Workbench.FactoryConnection.verify_usb!(usb)
          end

          report.("Uploading reviewed firmware; do not disconnect power")
          upload!(connection, plan.snapshot, report)
        end,
        usb
      )

      if plan[:before_update] do
        report.(
          "Firmware accepted. Waiting for a new boot, reviewed version and healthy state over #{if usb, do: "the same USB management path", else: "verified SSH"}. No upload will be retried."
        )

        verify_update(plan, report)
      else
        {:ok,
         "Firmware accepted; the device will reboot. Reconnect and verify its running version."}
      end
    after
      cleanup(plan)
    end
  end

  def review_message, do: "Review complete. No firmware has been sent."
  def expiry_message, do: "Firmware review expired"

  def cleanup(nil), do: :ok
  def cleanup(plan), do: File.rm_rf!(plan.dir)

  def image!(path) do
    case Workbench.FirmwareCommand.run("fwup", ["--verify", "-i", path],
           timeout: 15_000,
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      _ -> raise "Invalid firmware archive"
    end

    {metadata, 0} =
      Workbench.FirmwareCommand.run("fwup", ["-m", "-i", path],
        timeout: 15_000,
        stderr_to_stdout: true
      )

    metadata(metadata)
  end

  def metadata(text) do
    for line <- String.split(text, "\n"),
        [key, value] <- [String.split(line, "=", parts: 2)],
        key in [
          "meta-product",
          "meta-platform",
          "meta-architecture",
          "meta-version",
          "meta-vcs-identifier"
        ],
        into: %{},
        do: {key, value |> String.trim() |> String.trim("\"")}
  end

  def compatible!(image, device) do
    # QEMU updates remain owned by its simulator admission/lifecycle. This
    # workstation path updates only the supported physical controller.
    unless image["meta-platform"] == "ec100" and
             image["meta-platform"] == device["target"] and
             image["meta-platform"] == device["platform"] and
             is_binary(image["meta-architecture"]) and
             image["meta-architecture"] == device["architecture"] and
             image["meta-product"] == "nerves_gate" and device["product"] == "nerves_gate" and
             is_binary(image["meta-version"]) and is_binary(device["version"]) and
             current_source?(image["meta-vcs-identifier"]),
           do:
             raise(
               ArgumentError,
               "Firmware metadata and source revision do not match current physical EC100 requirements"
             )

    :ok
  end

  def hash!(path),
    do:
      File.stream!(path, 64 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

  def port!(value) when is_binary(value) do
    case Integer.parse(value) do
      {port, ""} -> port!(port)
      _ -> raise ArgumentError, "SSH port must be between 1 and 65535"
    end
  end

  def port!(port) when is_integer(port) and port in 1..65_535, do: port
  def port!(_), do: raise(ArgumentError, "SSH port must be between 1 and 65535")

  @doc false
  def same_reviewed_boot?(reviewed, current) do
    keys = ["target", "product", "version", "source_revision", "serial", "boot_id"]
    is_binary(reviewed["boot_id"]) and Map.take(reviewed, keys) == Map.take(current, keys)
  end

  @doc false
  def verified_update?(before_update, observed, version, revision) do
    observed["target"] == "ec100" and observed["product"] == "nerves_gate" and
      observed["version"] == version and source_matches?(revision, observed) and
      observed["serial"] == before_update["serial"] and is_binary(before_update["boot_id"]) and
      is_binary(observed["boot_id"]) and observed["boot_id"] != before_update["boot_id"] and
      observed["available"] == true and observed["firmware_validated"] == true and
      observed["ready"] == true and
      observed["pending"] == false and observed["recovering"] == false
  end

  defp current_source?(revision),
    do: is_binary(revision) and Regex.match?(~r/\A[0-9a-f]{40}(?:-dirty)?\z/, revision)

  defp source_matches?(revision, observed),
    do: current_source?(revision) and observed["source_revision"] == revision

  defp verify_update(plan, report),
    do: poll_update(plan, report, deadline(180_000))

  defp poll_update(plan, report, until) do
    if System.monotonic_time(:millisecond) >= until do
      {:error,
       "Firmware was accepted, but reconnect verification did not complete: no matching new boot with the reviewed version and healthy network state. Management access may be unavailable. Inspect the device; do not repeat the update automatically."}
    else
      verified =
        try do
          observed = Workbench.DeviceSSH.read_hardware!(plan[:usb] || plan.public.address, 2_000)

          verified_update?(
            plan.before_update,
            observed,
            plan.public.version,
            plan.public.source_revision
          )
        rescue
          _ -> false
        end

      if verified do
        report.(
          "Verified a new boot, unchanged device identity, reviewed firmware and healthy state over authenticated SSH."
        )

        {:ok,
         "Update verified over #{if plan[:usb], do: "USB", else: "SSH"}: new boot, reviewed firmware version and healthy state. No networking configuration was changed."}
      else
        Process.sleep(1_000)
        poll_update(plan, report, until)
      end
    end
  end

  defp upload!(connection, path, report) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5_000)
    :success = :ssh_connection.subsystem(connection, channel, ~c"fwup", 5_000)
    total = File.stat!(path).size

    Enum.reduce(File.stream!(path, 64 * 1024), 0, fn chunk, sent ->
      case :ssh_connection.send(connection, channel, chunk, 30_000) do
        :ok -> :ok
        _ -> raise "SSH upload stopped; outcome unknown. Inspect the device before retrying"
      end

      sent = sent + byte_size(chunk)
      report.("Sent #{div(sent * 100, total)}% of reviewed firmware")
      sent
    end)

    :ok = :ssh_connection.send_eof(connection, channel)
    Workbench.DeviceSSH.receive_result!(connection, channel, deadline(60_000), :discard, report)
    :ok
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end

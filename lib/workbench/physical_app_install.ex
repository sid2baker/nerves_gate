defmodule Workbench.PhysicalAppInstall do
  @moduledoc "Reviewed, one-shot installation of a new stopped app over strictly verified SSH."
  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))
  alias NervesGateSDK.Package
  alias Workbench.FirmwareUpdate
  @ttl 600_000

  def review!(project, address, report \\ fn _ -> :ok end) do
    {:ok, address} = host!(address)

    dir =
      Path.join(
        Workbench.root(),
        "_build/app-installs/#{Base.encode16(:crypto.strong_rand_bytes(16))}"
      )

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    snapshot = Path.join(dir, "application.ez")

    try do
      report.("Packaging application in an isolated build process")
      built = Workbench.Applications.package!(project, report, :temporary)

      try do
        File.cp!(built, snapshot)
      after
        File.rm(built)
      end

      File.chmod!(snapshot, 0o400)
      package = package!(snapshot)
      metadata = metadata(package)

      report.(
        "Verifying device identity, SDK and prepared application storage over SSH; no upload"
      )

      device = connect(address, fn connection -> read!(connection, review_command(metadata)) end)
      compatible!(metadata, device)

      %{
        public: %{
          kind: :app_install,
          token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
          address: address,
          project: project,
          app: metadata.app,
          version: metadata.version,
          sdk_requirement: metadata.sdk_requirement,
          serial: device["serial"],
          target: device["target"],
          firmware: device["firmware"],
          sha256: hash!(snapshot),
          bytes: File.stat!(snapshot).size
        },
        device: device,
        metadata: metadata,
        snapshot: snapshot,
        dir: dir,
        expires: System.monotonic_time(:millisecond) + @ttl
      }
    catch
      kind, reason ->
        File.rm_rf!(dir)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  @doc false
  def metadata(package) do
    %{
      app: to_string(package.app),
      version: package.version,
      sdk_requirement: package.main.env[:nerves_gate_sdk_requirement],
      platform:
        Enum.map(package.main.env[:nerves_gate_platform] || [], fn {app, version} ->
          [to_string(app), version]
        end)
    }
  end

  def confirmation!(%{public: %{kind: :app_install}} = plan, token, address) do
    cond do
      token != plan.public.token or not is_binary(token) ->
        raise ArgumentError, "Review the application and device first"

      address != plan.public.address ->
        raise ArgumentError, "Type the exact reviewed hostname/address"

      System.monotonic_time(:millisecond) >= plan.expires ->
        raise ArgumentError, "Application install review expired; review again"

      true ->
        :ok
    end
  end

  def install!(plan, report \\ fn _ -> :ok end) do
    try do
      confirmation!(plan, plan.public.token, plan.public.address)

      if hash!(plan.snapshot) != plan.public.sha256,
        do: raise("Reviewed application changed; review again")

      connect(plan.public.address, fn connection ->
        current = read!(connection, review_command(plan.metadata))
        compatible!(plan.metadata, current)

        unless current == plan.device,
          do: raise("Device, boot, storage or SDK changed; no package uploaded. Review again")

        remote_dir =
          "/tmp/nerves-gate-app-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}"

        remote_path = remote_dir <> "/application.ez"
        report.("Uploading the reviewed package over verified SSH. It will not be started")
        upload!(connection, plan.snapshot, remote_dir, remote_path)
        report.("Submitting one new-app installation. A lost reply will not be retried")
        result = read!(connection, install_command(plan, remote_dir, remote_path), 45_000)

        case result["outcome"] do
          "installed_stopped" ->
            {:ok,
             "Installed #{plan.public.app} #{plan.public.version} on #{plan.public.address}. Verified stopped and disabled; no application start, upgrade, firmware or routing command was sent."}

          "rejected" ->
            {:error,
             "Device rejected the reviewed install. Inspect application/storage state before reviewing again. No start or upgrade was requested."}

          _ ->
            {:error,
             "Installation verification is incomplete; outcome unknown. Inspect installed applications before any retry. No start or upgrade was requested."}
        end
      end)
    after
      cleanup(plan)
    end
  end

  def cleanup(nil), do: :ok
  def cleanup(%{dir: dir}), do: File.rm_rf!(dir)

  defp host!(address) do
    case Workbench.LANDiscovery.host(address) do
      {:ok, _} = result -> result
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp package!(path) do
    if File.stat!(path).size > 128 * 1024 * 1024,
      do: raise(ArgumentError, "Application packages must be no larger than 128 MiB")

    case Package.read(path) do
      {:ok, package} -> package
      _ -> raise ArgumentError, "Application package is invalid"
    end
  end

  @doc false
  def compatible!(metadata, device) do
    unless device["product"] == "nerves_gate" and device["target"] == "ec100" and
             is_binary(device["serial"]) and device["serial"] != "" and
             is_binary(device["boot_id"]) and
             Regex.match?(~r/\A[0-9a-f-]{36}\z/, device["boot_id"]),
           do: raise(ArgumentError, "SSH endpoint is not a compatible physical Nerves Gate")

    unless device["install_api"] == true,
      do:
        raise(
          ArgumentError,
          "Update device firmware first: reviewed application installation is unavailable"
        )

    unless device["storage_ready"] == true and is_binary(device["card_id"]),
      do:
        raise(
          ArgumentError,
          "Prepare an SD card under gateway Settings → Application storage first"
        )

    unless device["installed"] == false,
      do:
        raise(
          ArgumentError,
          "This application is already installed. Physical installation never upgrades, replaces or starts an existing app"
        )

    unless is_binary(device["sdk_version"]) and
             Version.match?(device["sdk_version"], metadata.sdk_requirement) and
             device["platform_compatible"] == true,
           do:
             raise(
               ArgumentError,
               "Device SDK or platform libraries do not meet this package's requirements"
             )

    :ok
  end

  @doc false
  def review_command(metadata) do
    args = Jason.encode!(metadata) |> Base.encode64()

    ~s|args = Jason.decode!(Base.decode64!(#{inspect(args)})); | <>
      ~S"""
      try do
        storage = NervesGate.Storage.commissioning()
        {:ok, apps} = NervesGate.Apps.list()
        info = NervesGate.System.info()
        platform = Enum.all?(args["platform"], fn [name, version] ->
          Enum.any?(Application.loaded_applications(), fn {app, _, current} -> to_string(app) == name and to_string(current) == version end)
        end)
        Base.encode64(Jason.encode!(%{
          product: Nerves.Runtime.KV.get_active("nerves_fw_product"), target: to_string(info.target),
          firmware: info.firmware, serial: Nerves.Runtime.serial_number(),
          boot_id: File.read!("/proc/sys/kernel/random/boot_id") |> String.trim(),
          sdk_version: to_string(Application.spec(:nerves_gate_sdk, :vsn)),
          install_api: function_exported?(NervesGate.Apps, :install_new, 2),
          storage_ready: storage.ready, card_id: storage.card_id,
          installed: Enum.any?(apps, &(to_string(&1.app) == args["app"])),
          platform_compatible: platform
        }))
      rescue
        _ -> Base.encode64(Jason.encode!(%{outcome: "unavailable"}))
      catch
        _, _ -> Base.encode64(Jason.encode!(%{outcome: "unavailable"}))
      end
      """
  end

  @doc false
  def install_command(plan, dir, path) do
    expected = %{
      app: plan.public.app,
      version: plan.public.version,
      sha256: plan.public.sha256,
      card_id: plan.device["card_id"]
    }

    """
    try do
      expected = #{inspect(expected)}
      result = NervesGate.Apps.install_new(#{inspect(path)}, expected)
      outcome = case result do
        {:ok, _} ->
          {:ok, apps} = NervesGate.Apps.list()
          if Enum.any?(apps, &(to_string(&1.app) == expected.app and &1.active_version == expected.version and &1.enabled == false and &1.running? == false)), do: "installed_stopped", else: "unknown"
        {:error, _} -> "rejected"
        _ -> "unknown"
      end
      Base.encode64(Jason.encode!(%{outcome: outcome}))
    rescue
      _ -> Base.encode64(Jason.encode!(%{outcome: "unknown"}))
    catch
      _, _ -> Base.encode64(Jason.encode!(%{outcome: "unknown"}))
    after
      File.rm_rf(#{inspect(dir)})
    end
    """
  end

  defp connect(address, run) do
    {:ok, _} = Application.ensure_all_started(:ssh)

    case :ssh.connect(to_charlist(address), 22, FirmwareUpdate.ssh_options(address), 15_000) do
      {:ok, connection} ->
        try do
          run.(connection)
        after
          :ssh.close(connection)
        end

      {:error, reason} ->
        raise FirmwareUpdate.connection_error(reason)
    end
  end

  defp read!(connection, command, timeout \\ 15_000) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5_000)

    try do
      :success = :ssh_connection.exec(connection, channel, to_charlist(command), 5_000)

      receive_result!(connection, channel, System.monotonic_time(:millisecond) + timeout, "")
      |> String.trim()
      |> String.trim("\"")
      |> Base.decode64!()
      |> JSON.decode!()
    after
      :ssh_connection.close(connection, channel)
    end
  rescue
    _ ->
      raise "SSH application operation did not return a verified result. Outcome may be unknown; inspect the device before retrying. No write is replayed automatically."
  end

  defp receive_result!(connection, channel, until, output) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, _, bytes}}
      when byte_size(output) + byte_size(bytes) <= 65_536 ->
        :ssh_connection.adjust_window(connection, channel, byte_size(bytes))
        receive_result!(connection, channel, until, output <> bytes)

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        receive_result!(connection, channel, until, output)

      {:ssh_cm, ^connection, {:exit_status, ^channel, 0}} ->
        output

      {:ssh_cm, ^connection, _} ->
        raise "SSH application response was incomplete"
    after
      max(until - System.monotonic_time(:millisecond), 0) ->
        raise "SSH application response timed out"
    end
  end

  defp upload!(connection, source, dir, destination) do
    {:ok, sftp} = :ssh_sftp.start_channel(connection, timeout: 5_000)

    try do
      unless :ssh_sftp.make_dir(sftp, to_charlist(dir), 5_000) == :ok,
        do:
          raise(
            "Could not reserve an owned upload directory. No install submitted; existing paths were left untouched"
          )

      upload_file!(sftp, source, dir, destination)
    after
      :ssh_sftp.stop_channel(sftp)
    end
  end

  defp upload_file!(sftp, source, dir, destination) do
    try do
      :ok = :ssh_sftp.write_file_info(sftp, to_charlist(dir), file_info(mode: 0o700), 5_000)
      {:ok, file} = :ssh_sftp.open(sftp, to_charlist(destination), [:write, :binary], 5_000)

      try do
        :ok =
          :ssh_sftp.write_file_info(sftp, to_charlist(destination), file_info(mode: 0o600), 5_000)

        until = System.monotonic_time(:millisecond) + 120_000

        for bytes <- File.stream!(source, 64 * 1024) do
          if System.monotonic_time(:millisecond) >= until, do: raise("Upload deadline exceeded")
          :ok = :ssh_sftp.write(sftp, file, bytes, 5_000)
        end
      after
        :ssh_sftp.close(sftp, file, 5_000)
      end
    rescue
      _ ->
        :ssh_sftp.delete(sftp, to_charlist(destination), 5_000)
        :ssh_sftp.del_dir(sftp, to_charlist(dir), 5_000)

        raise "Package upload did not complete. No install was submitted; inspect temporary files before reviewing again."
    end
  end

  defp hash!(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

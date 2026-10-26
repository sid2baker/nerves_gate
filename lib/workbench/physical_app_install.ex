defmodule Workbench.PhysicalAppInstall do
  @moduledoc "Reviewed, one-shot installation of a new stopped app over strictly verified SSH."
  alias NervesGateSDK.Package
  alias Workbench.DeviceSSH
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

      device =
        DeviceSSH.with_connection(address, 22, fn connection ->
          Workbench.DeviceSSH.read!(connection, review_command(metadata))
        end)

      compatible!(metadata, device)

      %{
        owner: __MODULE__,
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

      DeviceSSH.with_connection(plan.public.address, 22, fn connection ->
        current = Workbench.DeviceSSH.read!(connection, review_command(plan.metadata))
        compatible!(plan.metadata, current)

        unless current == plan.device,
          do: raise("Device, boot, storage or SDK changed; no package uploaded. Review again")

        remote_dir =
          "/tmp/nerves-gate-app-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}"

        remote_path = remote_dir <> "/application.ez"
        report.("Uploading the reviewed package over verified SSH. It will not be started")
        Workbench.DeviceSSH.upload!(connection, plan.snapshot, remote_dir, remote_path)
        report.("Submitting one new-app installation. A lost reply will not be retried")

        result =
          Workbench.DeviceSSH.read!(
            connection,
            install_command(plan, remote_path),
            200_000
          )

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

  def review_message,
    do:
      "Application install reviewed. No package uploaded or device changes made. Confirmation installs a new stopped app only."

  def expiry_message,
    do: "Application install review expired; review the package and device again"

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
  def review_command(metadata),
    do:
      Workbench.DeviceSSH.command(NervesGate.Apps, :install_review, [
        Jason.decode!(Jason.encode!(metadata))
      ])

  @doc false
  def install_command(plan, path) do
    expected = %{
      app: plan.public.app,
      version: plan.public.version,
      sha256: plan.public.sha256,
      card_id: plan.device["card_id"]
    }

    Workbench.DeviceSSH.command(NervesGate.Apps, :install_reviewed, [path, expected])
  end

  defp hash!(path),
    do: path |> File.read!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
end

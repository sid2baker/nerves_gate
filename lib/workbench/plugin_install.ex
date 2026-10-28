defmodule Workbench.PluginInstall do
  @moduledoc "Reviewed one-shot new plugin install over distribution; leaves it stopped and disabled."
  @ttl 600_000

  def review!(project, node, report) do
    {:ok, gateway} = Workbench.Gateways.fetch(node)
    dir = Path.join(Workbench.root(), "_build/plugin-installs/#{random()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    snapshot = Path.join(dir, "plugin.ez")

    try do
      built = Workbench.Plugins.package!(project, report, :temporary)

      try do
        File.cp!(built, snapshot)
      after
        File.rm(built)
      end

      File.chmod!(snapshot, 0o400)
      {:ok, package, _, sha} = NervesGate.Plugins.Artifact.read(snapshot)

      metadata = %{
        "plugin" => to_string(package.app),
        "platform" =>
          Enum.map(package.main.env[:nerves_gate_platform] || [], fn {app, version} ->
            [to_string(app), version]
          end)
      }

      device = observe!(gateway.node, metadata)
      compatible!(device, package.main.env[:nerves_gate_sdk_requirement])

      if device.serial != gateway.identity.serial,
        do: raise("Gateway identity changed; review again")

      %{
        owner: __MODULE__,
        dir: dir,
        snapshot: snapshot,
        metadata: metadata,
        device: device,
        expires: System.monotonic_time(:millisecond) + @ttl,
        expected: %{
          plugin: metadata["plugin"],
          version: package.version,
          sha256: sha,
          card_id: device.card_id
        },
        public: %{
          kind: :plugin_install,
          token: random(),
          node: gateway.node,
          address: gateway.address,
          plugin: metadata["plugin"],
          version: package.version,
          serial: device.serial,
          sha256: sha,
          project: project
        }
      }
    catch
      kind, reason ->
        File.rm_rf!(dir)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  def confirmation!(plan, token, address) do
    unless is_binary(token) and token == plan.public.token and address == plan.public.address and
             System.monotonic_time(:millisecond) < plan.expires,
           do: raise(ArgumentError, "Confirm the exact unexpired plugin review and address")

    :ok
  end

  def install!(plan, token, address, report) do
    confirmation!(plan, token, address)

    if Workbench.FirmwareUpdate.hash!(plan.snapshot) != plan.expected.sha256,
      do: raise("Reviewed package changed; no install sent")

    if observe!(plan.public.node, plan.metadata) != plan.device,
      do: raise("Gateway boot, storage or plugin prerequisites changed; review again")

    guest =
      "/tmp/nerves-gate-plugin-#{Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)}/plugin.ez"

    bytes = File.read!(plan.snapshot)
    :ok = :erpc.call(plan.public.node, File, :mkdir, [Path.dirname(guest)], 5_000)
    :ok = :erpc.call(plan.public.node, File, :write, [guest, bytes, [:exclusive]], 30_000)
    report.("Installing once; plugin will remain stopped and disabled")

    case :erpc.call(
           plan.public.node,
           NervesGate.Plugins,
           :install_reviewed,
           [guest, plan.expected],
           200_000
         ) do
      %{outcome: "installed_stopped"} ->
        {:ok, "Installed #{plan.public.app} #{plan.public.version}; stopped and disabled"}

      %{outcome: "rejected"} ->
        {:error, "Gateway rejected installation; inspect before reviewing again"}

      _ ->
        {:error, "Install outcome unknown. Inspect the gateway; do not retry automatically"}
    end
  catch
    :error, {:erpc, _} ->
      {:error, "Install outcome unknown. Inspect the gateway; do not retry automatically"}
  after
    cleanup(plan)
  end

  @doc false
  def compatible!(device, requirement) do
    unless device.product == "nerves_gate" and device.target in ["ec100", "x86_64"] and
             is_binary(device.serial) and device.serial != "" and is_binary(device.boot_id) and
             device.storage_ready and is_binary(device.card_id) and not device.installed and
             device.platform_compatible and is_binary(requirement) and
             Version.match?(device.sdk_version, requirement),
           do:
             raise(
               ArgumentError,
               "Requires compatible firmware/SDK, prepared storage and a new plugin"
             )

    :ok
  end

  def cleanup(%{dir: dir}), do: File.rm_rf!(dir)
  def cleanup(_), do: :ok

  defp observe!(node, metadata),
    do: :erpc.call(node, NervesGate.Plugins, :install_review, [metadata], 5_000)

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end

defmodule Workbench.FirmwareUpdate do
  @moduledoc """
  Reviewed physical EC100 firmware update. Identity, health and plugin-artifact
  preflight use distribution; the image is uploaded once over strictly verified
  SSH (`fwup` subsystem); success is a new healthy boot of the same gateway.
  Uncertain outcomes are never retried.
  """
  @ttl 600_000
  @keys ["target", "product", "version", "source_revision", "serial", "boot_id"]

  def review!(node, firmware, report \\ fn _ -> :ok end) do
    {:ok, gateway} = gateway!(node)
    original = Path.expand(firmware || "")

    unless Path.extname(original) == ".fw" and File.regular?(original),
      do: raise(ArgumentError, "Select an existing .fw file or build firmware first")

    if File.stat!(original).size > 512 * 1024 * 1024,
      do: raise(ArgumentError, "Firmware archives must be no larger than 512 MiB")

    dir = Path.join(Workbench.root(), "_build/firmware-updates/#{random()}")
    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    snapshot = Path.join(dir, "image.fw")

    try do
      File.cp!(original, snapshot)
      File.chmod!(snapshot, 0o400)
      report.("Checking the firmware archive")
      image = image!(snapshot)
      report.("Reading the gateway's identity, health and plugin artifacts")
      before = observe!(gateway.node)
      compatible!(image, before)
      healthy!(before)

      verify_ssh!(gateway.address)
      saved = saved_plugins!(gateway.node)
      catalog = catalog!(snapshot)

      case conflicts(saved, catalog) do
        [] ->
          :ok

        found ->
          raise "Plugin artifacts changed under existing versions: #{inspect(found)}. Bump versions and rebuild; no firmware sent."
      end

      %{
        owner: __MODULE__,
        public: %{
          kind: :firmware,
          token: random(),
          node: gateway.node,
          address: gateway.address,
          firmware: original,
          current_version: before["version"],
          version: image["meta-version"],
          source_revision: image["meta-vcs-identifier"],
          serial: before["serial"],
          sha256: hash!(snapshot)
        },
        snapshot: snapshot,
        dir: dir,
        before: before,
        saved_plugins: saved,
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

  def update!(plan, token, address, report \\ fn _ -> :ok end) do
    confirmation!(plan, token, address)

    if hash!(plan.snapshot) != plan.public.sha256,
      do: raise("Reviewed firmware changed; review again")

    unless same_boot?(plan.before, observe!(plan.public.node)),
      do: raise("Gateway rebooted or changed since review; no firmware sent. Review again")

    address = plan.public.address

    case Workbench.SSH.connect(address, 22, Workbench.SSH.verified(address)) do
      {:ok, connection} ->
        try do
          unless same_boot?(plan.before, observe!(plan.public.node)) and
                   healthy?(observe!(plan.public.node)) and
                   saved_plugins!(plan.public.node) == plan.saved_plugins,
                 do: raise("Gateway state changed since review; no firmware sent. Review again")

          report.("Uploading reviewed firmware; do not disconnect power")
          :ok = Workbench.SSH.upload_firmware(connection, plan.snapshot, report)
        after
          :ssh.close(connection)
        end

      {:error, reason} ->
        raise "SSH connection failed (#{inspect(reason)}). Verify the host key in ~/.ssh/known_hosts and your authorized key. No firmware sent."
    end

    report.(
      "Firmware accepted. Waiting up to three minutes for a new healthy boot. No upload will be retried."
    )

    await_new_boot(plan, System.monotonic_time(:millisecond) + 180_000)
  after
    cleanup(plan)
  end

  defp verify_ssh!(address) do
    case Workbench.SSH.connect(address, 22, Workbench.SSH.verified(address)) do
      {:ok, connection} -> :ssh.close(connection)
      {:error, _} -> raise "Verify the gateway's SSH host key and authorized key before reviewing"
    end
  end

  def cleanup(%{dir: dir}), do: File.rm_rf!(dir)
  def cleanup(_), do: :ok

  defp await_new_boot(plan, deadline) do
    observed =
      try do
        observe!(plan.public.node)
      catch
        _, _ -> nil
      end

    cond do
      observed && verified?(plan, observed) ->
        {:ok,
         "Update verified: new boot of serial #{plan.public.serial} running #{plan.public.version}, healthy."}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error,
         "Firmware was accepted, but no matching healthy new boot was observed. Inspect the gateway; do not repeat the update automatically."}

      true ->
        Process.sleep(2_000)
        await_new_boot(plan, deadline)
    end
  end

  @doc false
  def verified?(plan, observed) do
    observed["serial"] == plan.before["serial"] and observed["boot_id"] != plan.before["boot_id"] and
      observed["version"] == plan.public.version and
      observed["source_revision"] == plan.public.source_revision and healthy?(observed)
  end

  @doc false
  def same_boot?(before, current), do: Map.take(before, @keys) == Map.take(current, @keys)

  defp healthy?(observed),
    do:
      observed["available"] == true and observed["firmware_validated"] == true and
        observed["pending"] == false and observed["recovering"] == false

  defp healthy!(observed) do
    unless healthy?(observed),
      do:
        raise(
          "Wait for validated firmware and no pending network trial or recovery before updating"
        )
  end

  defp observe!(node) do
    node
    |> :erpc.call(NervesGate.System, :hardware_info, [], 5_000)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp saved_plugins!(node) do
    {:ok, saved} =
      :erpc.call(
        node,
        NervesGate.Plugins.Metadata,
        :read,
        ["/data/nerves_gate/plugins.term"],
        5_000
      )

    saved
  end

  defp gateway!(node) do
    case Workbench.Gateways.fetch(node) do
      {:ok, gateway} -> {:ok, gateway}
      _ -> raise ArgumentError, "Select a connected gateway"
    end
  end

  @doc false
  def conflicts(saved, catalog) do
    for {app, entry} <- catalog,
        {version, artifact} <- entry.artifacts,
        old = get_in(saved, [app, :artifacts, version]),
        old != nil and old != artifact,
        do: {app, version}
  end

  @doc "The plugin inventory inside the exact firmware archive."
  def catalog!(firmware) do
    dir = Path.join(System.tmp_dir!(), "gate-update-#{random()}")
    File.mkdir_p!(dir)

    try do
      {:ok, [{_, rootfs}]} =
        :zip.extract(String.to_charlist(firmware), [:memory, file_list: [~c"data/rootfs.img"]])

      path = Path.join(dir, "rootfs.img")
      File.write!(path, rootfs)

      {bytes, 0} =
        Workbench.FirmwareCommand.run(
          "unsquashfs",
          ["-cat", path, "srv/erlang/lib/nerves_gate-*/priv/plugins/inventory.term"],
          timeout: 30_000
        )

      %{schema: 2, entries: entries} = :erlang.binary_to_term(bytes)
      entries
    after
      File.rm_rf!(dir)
    end
  end

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
        key in ~w(meta-product meta-platform meta-architecture meta-version meta-vcs-identifier),
        into: %{},
        do: {key, value |> String.trim() |> String.trim("\"")}
  end

  def compatible!(image, device) do
    unless image["meta-platform"] == "ec100" and device["target"] == "ec100" and
             image["meta-platform"] == device["platform"] and
             is_binary(image["meta-architecture"]) and
             image["meta-architecture"] == device["architecture"] and
             image["meta-product"] == "nerves_gate" and device["product"] == "nerves_gate" and
             is_binary(image["meta-version"]) and
             Regex.match?(~r/\A[0-9a-f]{40}(?:-dirty)?\z/, image["meta-vcs-identifier"] || ""),
           do:
             raise(
               ArgumentError,
               "Firmware metadata and source revision do not match a physical EC100 gateway"
             )

    :ok
  end

  def hash!(path),
    do:
      File.stream!(path, 64 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

  defp random, do: Base.url_encode64(:crypto.strong_rand_bytes(18), padding: false)
end

defmodule Workbench.DeviceUpdate do
  @moduledoc "One-shot physical firmware update through the running Workbench's reviewed operation queue."

  alias Workbench.{DeviceSSH, FirmwareCommand, FirmwareUpdate, Session}

  @doc "Update explicitly authorized hardware once. Never retries an uncertain write or selects/starts plugins."
  def update(host, firmware) do
    firmware = Path.expand(firmware)
    image = FirmwareUpdate.image!(firmware)
    sha = FirmwareUpdate.hash!(firmware)
    catalog = catalog!(firmware)
    {client, state} = Session.connect() || raise("Start mix dev before updating firmware")

    unless state["operation"]["status"] in ~w(idle succeeded failed),
      do: raise("Workbench is busy; inspect its current operation")

    identity =
      DeviceSSH.with_connection(host, 22, fn connection ->
        identity = DeviceSSH.identity!(connection)
        FirmwareUpdate.compatible!(image, identity)

        query =
          "{:ok, saved} = NervesGate.Plugins.Metadata.read(\"/data/nerves_gate/plugins.term\"); Base.encode64(Jason.encode!(Base.encode64(:erlang.term_to_binary(saved))))"

        saved = DeviceSSH.read!(connection, query) |> Base.decode64!() |> :erlang.binary_to_term()

        case conflicts(saved, catalog) do
          [] ->
            identity

          conflicts ->
            raise(
              "Plugin artifacts changed under existing versions: #{inspect(conflicts)}. Bump versions and rebuild; no firmware sent."
            )
        end
      end)

    post!(client, "/api/firmware/review",
      address: host,
      port: "22",
      firmware: firmware,
      verify_usb: "ssh"
    )

    review = await!(client, "firmware_review", 60_000)["review"]
    verify_review!(review, identity, host, image, sha)
    post!(client, "/api/firmware/confirm", address: host, review_id: review["token"])
    operation = await!(client, "firmware_update", 300_000)

    unless operation["status"] == "succeeded",
      do: raise("Update not verified; inspect the Workbench. Do not replay.")

    plugins =
      DeviceSSH.with_connection(host, 22, fn connection ->
        query =
          "Base.encode64(Jason.encode!(case NervesGate.Plugins.list() do {:ok, plugins} -> %{plugins: plugins}; {:error, reason} -> %{error: inspect(reason)} end))"

        case DeviceSSH.read!(connection, query) do
          %{"plugins" => entries} when is_list(entries) ->
            entries

          _ ->
            raise(
              "Firmware boot verified, but plugin management is unavailable. Inspect; do not reflash."
            )
        end
      end)

    {:ok,
     %{
       address: host,
       serial: review["serial"],
       sha256: sha,
       source_revision: review["source_revision"],
       result: operation["result"],
       plugins:
         Enum.map(plugins, &Map.take(&1, ~w(app active_version available_version running? error)))
     }}
  rescue
    error -> {:error, Exception.message(error)}
  end

  @doc false
  def conflicts(saved, catalog) do
    for {app, entry} <- catalog,
        {version, artifact} <- entry.artifacts,
        old = get_in(saved, [app, :artifacts, version]),
        old != nil and old != artifact,
        do: {app, version}
  end

  @doc false
  def verify_review!(review, identity, host, image, sha) do
    unless review["serial"] == identity["serial"] and review["address"] == host and
             review["source_revision"] == image["meta-vcs-identifier"] and review["sha256"] == sha and
             review["verify_ssh"] == true do
      raise("Firmware review does not match preflight; nothing confirmed")
    end

    :ok
  end

  @doc false
  def catalog!(firmware) do
    dir =
      Path.join(System.tmp_dir!(), "gate-update-#{Base.encode16(:crypto.strong_rand_bytes(8))}")

    File.mkdir_p!(dir)

    try do
      {:ok, [{_, rootfs}]} =
        :zip.extract(String.to_charlist(firmware), [:memory, file_list: [~c"data/rootfs.img"]])

      path = Path.join(dir, "rootfs.img")
      File.write!(path, rootfs)

      {bytes, 0} =
        FirmwareCommand.run(
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

  defp post!(client, url, form) do
    case Req.post(client, url: url, form: form, retry: false) do
      {:ok, %{status: 200, body: %{"ok" => true}}} ->
        :ok

      _ ->
        raise(
          "Workbench request outcome unknown. Inspect its operation; do not repeat the update."
        )
    end
  end

  defp await!(client, kind, timeout),
    do: poll!(client, kind, System.monotonic_time(:millisecond) + timeout)

  defp poll!(client, kind, deadline) do
    {:ok, %{status: 200, body: state}} = Req.get(client, url: "/api/state", retry: false)
    operation = state["operation"]

    cond do
      operation["kind"] != kind ->
        raise("Workbench operation changed; inspect before continuing")

      operation["status"] in ~w(succeeded awaiting_confirmation) ->
        operation

      operation["status"] != "running" ->
        raise("Workbench operation failed: #{operation["result"]}. Inspect; do not replay.")

      System.monotonic_time(:millisecond) >= deadline ->
        raise("Operation pending. Inspect the Workbench; do not repeat the update.")

      true ->
        Process.sleep(1_000)
        poll!(client, kind, deadline)
    end
  end
end

defmodule Dev.FirmwareUpdate do
  @moduledoc "Explicit SSH firmware review/update; never provisions disks or bypasses host-key checks."
  @ttl 600_000
  @identity ~S|Base.encode64(Jason.encode!(%{target: to_string(NervesGate.target()), version: to_string(Application.spec(:nerves_gate, :vsn)), platform: Nerves.Runtime.KV.get_active("nerves_fw_platform"), architecture: Nerves.Runtime.KV.get_active("nerves_fw_architecture"), product: Nerves.Runtime.KV.get_active("nerves_fw_product"), serial: Nerves.Runtime.serial_number()}))|

  @doc false
  def identity_command, do: @identity

  def read_device!(address) do
    {:ok, host} = valid_host!(address)
    device = with_connection(host, 22, &identity!/1)

    unless device["product"] == "nerves_gate" and
             Enum.all?(["target", "version", "platform", "architecture"], fn key ->
               is_binary(device[key]) and device[key] != ""
             end),
           do: raise("SSH endpoint did not return a compatible Nerves Gate identity")

    device
  end

  def review!(params, report \\ fn _ -> :ok end) do
    {:ok, host} = valid_host!(params["address"])
    port = port!(params["port"] || 22)
    original = Path.expand(params["firmware"] || "")

    unless Path.extname(original) == ".fw" and File.regular?(original),
      do: raise(ArgumentError, "Select an existing .fw file or build firmware first")

    if File.stat!(original).size > 512 * 1024 * 1024,
      do: raise(ArgumentError, "Firmware archives must be no larger than 512 MiB")

    dir =
      Path.join(
        Dev.root(),
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
      device = with_connection(host, port, &identity!/1)
      compatible!(image, device)

      public = %{
        token: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
        address: host,
        port: port,
        firmware: original,
        target: image["meta-platform"],
        architecture: image["meta-architecture"],
        current_version: device["version"],
        version: image["meta-version"],
        serial: device["serial"],
        sha256: hash!(snapshot)
      }

      %{
        public: public,
        snapshot: snapshot,
        dir: dir,
        device: device,
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

      with_connection(plan.public.address, plan.public.port, fn connection ->
        # DNS or device state may have changed since review. Check again before
        # opening the fwup subsystem, which admits a device-side state change.
        if identity!(connection) != plan.device,
          do: raise("Device identity/version changed; no firmware sent. Review again")

        report.("Uploading reviewed firmware; do not disconnect power")
        upload!(connection, plan.snapshot, report)
      end)

      "Firmware accepted; the device will reboot. Reconnect and verify its running version."
    after
      cleanup(plan)
    end
  end

  def cleanup(nil), do: :ok
  def cleanup(plan), do: File.rm_rf!(plan.dir)

  def image!(path) do
    case MuonTrap.cmd("fwup", ["--verify", "-i", path], timeout: 15_000, stderr_to_stdout: true) do
      {_, 0} -> :ok
      _ -> raise "Invalid firmware archive"
    end

    {metadata, 0} =
      MuonTrap.cmd("fwup", ["-m", "-i", path], timeout: 15_000, stderr_to_stdout: true)

    metadata(metadata)
  end

  def metadata(text) do
    for line <- String.split(text, "\n"),
        [key, value] <- [String.split(line, "=", parts: 2)],
        key in ["meta-product", "meta-platform", "meta-architecture", "meta-version"],
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
             is_binary(image["meta-version"]) and is_binary(device["version"]),
           do:
             raise(
               ArgumentError,
               "Firmware product/platform/architecture does not match a physical EC100 device"
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

  def ssh_options(host) do
    [
      key_cb:
        {Dev.SSHClient,
         [host: to_charlist(host), agent: not is_nil(System.get_env("SSH_AUTH_SOCK"))]},
      user: ~c"nerves_gate",
      auth_methods: ~c"publickey",
      user_interaction: false,
      silently_accept_hosts: false,
      save_accepted_host: false,
      connect_timeout: 10_000
    ]
  end

  defp valid_host!(address) do
    case Dev.Discovery.host(address) do
      {:ok, _} = host -> host
      {:error, message} -> raise ArgumentError, message
    end
  end

  defp with_connection(host, port, run) do
    {:ok, _} = Application.ensure_all_started(:ssh)

    case :ssh.connect(to_charlist(host), port, ssh_options(host), 15_000) do
      {:ok, connection} ->
        try do
          run.(connection)
        after
          :ssh.close(connection)
        end

      {:error, reason} ->
        raise connection_error(reason)
    end
  end

  @doc false
  def connection_error(reason) do
    detail =
      case reason do
        :timeout ->
          "SSH connection timed out. Check that the device is reachable on port 22."

        :econnrefused ->
          "SSH connection refused. Check that the device is listening on port 22."

        :nxdomain ->
          "Device hostname could not be resolved. Check DNS/Tailscale connectivity."

        ~c"Service not available" ->
          "SSH server rejected authentication or the requested service. Verify the requested hostname in known_hosts and check that the agent offers an authorized key."

        _ ->
          "SSH connection failed. Verify the host key and authorize your key."
      end

    detail <>
      " Uses nerves_gate with public-key authentication, SSH_AUTH_SOCK (if set), and ~/.ssh/known_hosts. Password prompts and unknown host keys are not accepted."
  end

  defp identity!(connection) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5_000)
    :success = :ssh_connection.exec(connection, channel, to_charlist(@identity), 5_000)
    response = receive_result!(connection, channel, deadline(15_000), "", fn _ -> :ok end)
    data = response |> String.trim() |> String.trim("\"") |> Base.decode64!() |> JSON.decode!()
    Map.take(data, ["target", "version", "platform", "architecture", "product", "serial"])
  rescue
    _ ->
      raise "SSH endpoint did not return a compatible Nerves Gate identity. No firmware was sent."
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
    receive_result!(connection, channel, deadline(60_000), :discard, report)
    :ok
  end

  defp receive_result!(connection, channel, deadline, output, report) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, _, data}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(data))
        output = if output == :discard, do: :discard, else: output <> data
        if is_binary(output) and byte_size(output) > 65_536, do: raise("SSH response too large")
        if output == :discard, do: report.(NervesGateSim.Simulator.BuildOutput.line(data))
        receive_result!(connection, channel, deadline, output, report)

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        receive_result!(connection, channel, deadline, output, report)

      {:ssh_cm, ^connection, {:exit_status, ^channel, 0}} ->
        :ssh_connection.close(connection, channel)
        output

      {:ssh_cm, ^connection, {:exit_status, ^channel, _}} ->
        raise "Device rejected SSH operation; inspect it before retrying"

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        raise "SSH closed without success; outcome unknown. Inspect the device before retrying"
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        raise "SSH timed out; outcome unknown. Inspect the device before retrying"
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end

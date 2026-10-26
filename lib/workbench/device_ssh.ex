defmodule Workbench.DeviceSSH do
  @moduledoc "Strict physical-device SSH trust, bounded requests and private package staging. No write retries."
  @hardware "Base.encode64(Jason.encode!(NervesGate.System.hardware_info()))"
  @identity "Base.encode64(Jason.encode!(NervesGate.System.maintenance_info()))"
  def identity_command, do: @identity

  def read_device!(address) do
    {:ok, host} = host!(address)
    device = Workbench.DeviceSSH.with_connection(host, 22, &identity!/1)

    unless device["product"] == "nerves_gate" and
             Enum.all?(["target", "version", "platform", "architecture"], fn key ->
               is_binary(device[key]) and device[key] != ""
             end) and current_source?(device["source_revision"]),
           do: raise("SSH endpoint did not return a compatible Nerves Gate identity")

    device
  end

  def hardware_command, do: @hardware

  def read_hardware!(target, timeout \\ 5_000)

  def read_hardware!(address, timeout) when is_binary(address) do
    {:ok, host} = host!(address)

    Workbench.DeviceSSH.with_connection(
      host,
      22,
      &Workbench.DeviceSSH.read!(&1, @hardware, timeout),
      nil,
      timeout
    )
    |> hardware_snapshot!()
  end

  def read_hardware!(peer, timeout) when is_map(peer) do
    :ok = Workbench.FactoryConnection.verify_usb!(peer)

    data =
      Workbench.DeviceSSH.with_connection(
        peer.address,
        22,
        &Workbench.DeviceSSH.read!(&1, @hardware, timeout),
        peer,
        timeout
      )

    :ok = Workbench.FactoryConnection.verify_usb!(peer)
    hardware_snapshot!(data)
  end

  def hardware_snapshot!(data) do
    unless data["target"] == "ec100" and data["product"] == "nerves_gate" and
             is_binary(data["version"]) and current_source?(data["source_revision"]) and
             is_binary(data["serial"]) and data["serial"] != "" and
             is_binary(data["boot_id"]) and Regex.match?(~r/\A[0-9a-f-]{36}\z/, data["boot_id"]),
           do:
             raise("SSH endpoint did not return a compatible EC100 identity and boot observation")

    data
    |> Map.take([
      "target",
      "version",
      "source_revision",
      "product",
      "serial",
      "boot_id",
      "available",
      "firmware_validated",
      "ready",
      "pending",
      "recovering"
    ])
    |> Map.put(
      "internet",
      Map.take(data["internet"] || %{}, [
        "mode",
        "selected",
        "ethernet",
        "cellular",
        "health",
        "ethernet_link"
      ])
    )
    |> Map.put(
      "cellular",
      Map.take(data["cellular"] || %{}, ["supported", "present", "enabled", "sim", "registration"])
    )
  end

  defp current_source?(revision),
    do: is_binary(revision) and Regex.match?(~r/\A[0-9a-f]{40}(?:-dirty)?\z/, revision)

  def identity!(connection) do
    connection
    |> Workbench.DeviceSSH.read!(@identity)
    |> Map.take([
      "target",
      "version",
      "platform",
      "architecture",
      "product",
      "serial",
      "source_revision"
    ])
  end

  def host!(address) do
    case Workbench.LANDiscovery.host(address) do
      {:ok, _} = host -> host
      {:error, message} -> raise ArgumentError, message
    end
  end

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  def options(host, usb \\ nil) do
    options = [
      key_cb:
        {Workbench.SSHHostKeys,
         [host: to_charlist(host), agent: not is_nil(System.get_env("SSH_AUTH_SOCK"))]},
      user: ~c"nerves_gate",
      auth_methods: ~c"publickey",
      user_interaction: false,
      silently_accept_hosts: false,
      save_accepted_host: false,
      connect_timeout: 10_000
    ]

    if usb,
      do: Keyword.merge(options, ip: usb.local, bind_to_device: usb.interface),
      else: options
  end

  def with_connection(host, port, run, usb \\ nil, timeout \\ 15_000) do
    {:ok, _} = Application.ensure_all_started(:ssh)
    if usb, do: Workbench.FactoryConnection.verify_usb!(usb)
    options = Keyword.put(options(host, usb), :connect_timeout, timeout)

    case :ssh.connect(to_charlist(host), port, options, timeout) do
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

  def connection_error(reason) do
    detail =
      case reason do
        :timeout ->
          "SSH connection timed out. Check that the device is reachable on port 22."

        :econnrefused ->
          "SSH connection refused. Check that the device is listening on port 22."

        :nxdomain ->
          "Device hostname could not be resolved. Check DNS/Tailscale connectivity."

        denied when denied in [:eacces, :eperm] ->
          "SSH transport permission denied. USB procedures require host permission to bind the management interface."

        ~c"Service not available" ->
          "SSH server rejected authentication or the requested service. Verify the requested hostname in known_hosts and check that the agent offers an authorized key."

        _ ->
          "SSH connection failed. Verify the host key and authorize your key."
      end

    detail <>
      " Uses nerves_gate with public-key authentication, SSH_AUTH_SOCK (if set), and ~/.ssh/known_hosts. Password prompts and unknown host keys are not accepted."
  end

  def command(module, function, args \\ []) do
    arguments =
      Enum.map_join(args, ", ", &inspect(&1, limit: :infinity, printable_limit: :infinity))

    "Base.encode64(Jason.encode!(#{inspect(module)}.#{function}(#{arguments})))"
  end

  def read!(connection, command, timeout \\ 15_000) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5_000)

    try do
      :success = :ssh_connection.exec(connection, channel, to_charlist(command), 5_000)

      receive_result!(
        connection,
        channel,
        System.monotonic_time(:millisecond) + timeout,
        "",
        fn _ -> :ok end
      )
      |> String.trim()
      |> String.trim("\"")
      |> Base.decode64!()
      |> JSON.decode!()
    after
      :ssh_connection.close(connection, channel)
    end
  rescue
    _ ->
      raise "SSH operation did not return a verified result; outcome may be unknown. Inspect the device before retrying. No write is replayed automatically."
  end

  def receive_result!(connection, channel, deadline, output, report) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, _, data}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(data))
        output = append(output, data, report)
        receive_result!(connection, channel, deadline, output, report)

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        receive_result!(connection, channel, deadline, output, report)

      {:ssh_cm, ^connection, {:exit_status, ^channel, 0}} ->
        output

      {:ssh_cm, ^connection, event}
      when is_tuple(event) and tuple_size(event) > 1 and elem(event, 1) == channel ->
        raise "SSH closed without success; outcome unknown. Inspect the device before retrying"

      {:ssh_cm, ^connection, _other_channel_event} ->
        receive_result!(connection, channel, deadline, output, report)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        raise "SSH timed out; outcome unknown. Inspect the device before retrying"
    end
  end

  defp append(:discard, data, report) do
    report.(Simulator.BuildOutput.line(data))
    :discard
  end

  defp append(output, data, _) when byte_size(output) + byte_size(data) <= 65_536,
    do: output <> data

  defp append(_, _, _), do: raise("SSH response too large")

  def upload!(connection, source, dir, destination) do
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
end

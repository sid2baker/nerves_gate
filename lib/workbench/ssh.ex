defmodule Workbench.SSH do
  @moduledoc """
  SSH is used only to upload firmware through the device's `fwup` subsystem and by
  SSH scenarios. Everything else talks to gateways over distribution.
  """

  @doc "Strict physical-gateway options: known host key, public key, never a password prompt."
  def verified(host) do
    [
      key_cb:
        {Workbench.SSHHostKeys,
         [host: to_charlist(host), agent: not is_nil(System.get_env("SSH_AUTH_SOCK"))]},
      user: ~c"nerves_gate",
      auth_methods: ~c"publickey",
      silently_accept_hosts: false
    ]
  end

  def connect(host, port, options) do
    {:ok, _} = Application.ensure_all_started(:ssh)

    :ssh.connect(
      to_charlist(host),
      port,
      options ++ [user_interaction: false, save_accepted_host: false, connect_timeout: 5_000],
      10_000
    )
  end

  @doc "Upload once. Any failure after the first byte has an unknown outcome and is never retried."
  def upload_firmware(connection, path, report \\ fn _ -> :ok end) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5_000)
    :success = :ssh_connection.subsystem(connection, channel, ~c"fwup", 5_000)
    total = max(File.stat!(path).size, 1)

    Enum.reduce(File.stream!(path, 64 * 1024), 0, fn chunk, sent ->
      unless :ssh_connection.send(connection, channel, chunk, 30_000) == :ok,
        do: raise("SSH upload stopped; outcome unknown. Inspect the device before retrying")

      sent = sent + byte_size(chunk)
      report.("Sent #{div(sent * 100, total)}% of firmware")
      sent
    end)

    :ok = :ssh_connection.send_eof(connection, channel)
    await_exit(connection, channel, System.monotonic_time(:millisecond) + 60_000)
  end

  defp await_exit(connection, channel, deadline) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, _, data}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(data))
        await_exit(connection, channel, deadline)

      {:ssh_cm, ^connection, {:exit_status, ^channel, 0}} ->
        :ok

      {:ssh_cm, ^connection, {:exit_status, ^channel, _}} ->
        raise "Device rejected the firmware"

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        raise "SSH closed without success; outcome unknown. Inspect the device before retrying"

      {:ssh_cm, ^connection, _} ->
        await_exit(connection, channel, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        raise "SSH upload timed out; outcome unknown. Inspect the device before retrying"
    end
  end
end

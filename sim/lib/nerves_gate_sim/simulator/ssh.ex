defmodule NervesGateSim.Simulator.SSH do
  @moduledoc "Real SSH recovery, provisioning and firmware transport for owned simulator devices."

  def connect(device, options \\ []) do
    :ssh.connect(
      String.to_charlist(device.address),
      device.forwards.usb,
      options ++
        [
          user: ~c"root",
          password: ~c"nerves_gate",
          auth_methods: ~c"password",
          silently_accept_hosts: true,
          save_accepted_host: false,
          user_interaction: false,
          connect_timeout: 3000
        ],
      5000
    )
  end

  def upload(connection, firmware) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    :success = :ssh_connection.subsystem(connection, channel, ~c"fwup", 5000)

    for chunk <- File.stream!(firmware, 64 * 1024) do
      :ok = :ssh_connection.send(connection, channel, chunk, 30_000)
    end

    :ok = :ssh_connection.send_eof(connection, channel)
    receive_result(connection, channel, deadline(60_000), :discard)
    :ok
  end

  # NervesSSH's normal exec interface evaluates Elixir. Only public domain
  # commands are sent here; no state files or trusted USB-access maps are injected.
  def request(connection, expression) do
    {:ok, channel} = :ssh_connection.session_channel(connection, 5000)
    command = "Base.encode64(:erlang.term_to_binary(#{expression}))"
    :success = :ssh_connection.exec(connection, channel, String.to_charlist(command), 5000)
    output = receive_result(connection, channel, deadline(90_000), "")
    # NervesSSH returns inspect/1 of the expression's result (a Base64 string).
    output
    |> String.trim()
    |> String.trim("\"")
    |> Base.decode64!()
    |> :erlang.binary_to_term([:safe])
  end

  def provision(connection, config) do
    for key <- Map.get(config, :ssh_keys, []) do
      :ok = request(connection, "NervesGate.ssh_add_key(#{inspect(key)})")
    end

    if settings = config[:network] do
      await_action(connection, "network.propose", deadline(30_000))
      {:ok, trial} = request(connection, "NervesGate.network_propose(#{inspect(settings)})")
      await_action(connection, "network.confirm", deadline(30_000))
      :ok = request(connection, "NervesGate.network_confirm(#{inspect(trial)})")
    end

    :ok
  end

  defp await_action(connection, action, deadline) do
    if request(connection, "NervesGate.status().actions[#{inspect(action)}].enabled") do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline,
        do: raise("Provisioning did not become ready for #{action}")

      Process.sleep(250)
      await_action(connection, action, deadline)
    end
  end

  defp receive_result(connection, channel, deadline, output) do
    receive do
      {:ssh_cm, ^connection, {:data, ^channel, _type, data}} ->
        :ssh_connection.adjust_window(connection, channel, byte_size(data))
        output = if output == :discard, do: output, else: output <> data
        if is_binary(output) and byte_size(output) > 65_536, do: raise("SSH response too large")
        receive_result(connection, channel, deadline, output)

      {:ssh_cm, ^connection, {:eof, ^channel}} ->
        receive_result(connection, channel, deadline, output)

      {:ssh_cm, ^connection, {:exit_status, ^channel, 0}} ->
        output

      {:ssh_cm, ^connection, {:exit_status, ^channel, _}} ->
        raise "Device rejected SSH operation"

      {:ssh_cm, ^connection, {:closed, ^channel}} ->
        raise "SSH closed without a successful exit status"
    after
      max(deadline - System.monotonic_time(:millisecond), 0) ->
        raise "SSH operation timed out; outcome is unknown"
    end
  end

  defp deadline(timeout), do: System.monotonic_time(:millisecond) + timeout
end

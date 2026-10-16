defmodule Mix.Tasks.Dev.Qemu do
  @moduledoc false
  use Mix.Task
  @shortdoc "Boot one disposable QEMU and its /tests page"

  @impl true
  def run(args) do
    options = options!(args)
    Mix.Task.run("compile")

    dir =
      Path.expand(if options[:ci], do: "_build/qemu-ci-#{System.pid()}", else: "_build/qemu-dev")

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)

    # Execute flock before MuonTrap so the OS wrapper owns the lock throughout
    # child cleanup, even when this BEAM aborts. Never unlink the lock file.
    flock = System.find_executable("flock") || Mix.raise("Install flock (util-linux)")

    port =
      Port.open({:spawn_executable, flock}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: [
          "--nonblock",
          "--conflict-exit-code",
          "75",
          "--no-fork",
          Path.join(dir, "session.lock"),
          MuonTrap.muontrap_path(),
          "--capture-output",
          "--capture-stderr",
          "--",
          "mix",
          "run",
          "--no-start",
          "dev/qemu_host.exs",
          dir | args
        ],
        env: [{~c"MIX_TARGET", ~c"host"}, {~c"MIX_ENV", Atom.to_charlist(Mix.env())}]
      ])

    status =
      try do
        session_output(port)
      after
        if Port.info(port), do: Port.close(port)
      end

    case status do
      0 -> :ok
      75 -> Mix.raise("A QEMU session is already running. Stop it before starting another.")
      _ -> Mix.raise("QEMU session failed (exit #{status})")
    end
  end

  defp session_output(port) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(data)
        MuonTrap.Port.report_bytes_handled(port, byte_size(data))
        session_output(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  # Entered only by dev/qemu_host.exs, under flock and MuonTrap.
  def session(dir, args) do
    options = options!(args)
    ci? = options[:ci] || false
    port = options[:port] || 4000
    socket = Path.join(dir, "http.sock")
    unless ci?, do: check_port!(port)
    File.rm(socket)
    {:ok, _} = Application.ensure_all_started(:muontrap)

    check_tools!()

    try do
      build_firmware!()
      IO.puts("Starting QEMU; waiting for the device and Phoenix...")

      status =
        if ci? do
          run_session(true, socket, options[:only] || "all", port)
        else
          serve(port, socket)
        end

      if status != 0, do: Mix.raise("QEMU session failed (exit #{status})")
    after
      File.rm(socket)
    end
  end

  defp check_tools! do
    for tool <- ["qemu-system-x86_64", "fwup"] do
      unless System.find_executable(tool),
        do: Mix.raise("Install #{tool}; see docs/development.md#prerequisites.")
    end
  end

  defp options!(args) do
    {options, []} =
      OptionParser.parse!(args, strict: [port: :integer, ci: :boolean, only: :string])

    options
  end

  defp serve(port, socket) do
    {:ok, _} = Application.ensure_all_started(:req)
    task = Task.async(fn -> run_session(false, socket, "all", port) end)

    try do
      await_http(task, socket, port, System.monotonic_time(:millisecond) + 240_000)
      IO.puts("QEMU ready: http://localhost:#{port}/tests")
      Task.await(task, :infinity)
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp await_http(task, socket, port, deadline) do
    case Task.yield(task, 100) do
      {:ok, status} -> Mix.raise("QEMU exited before HTTP was ready (exit #{status})")
      nil -> :ok
    end

    options = [
      retry: false,
      redirect: false,
      connect_options: [timeout: 200],
      receive_timeout: 500
    ]

    with {:ok, %{status: 200}} <-
           Req.get("http://localhost/tests/state", [unix_socket: socket] ++ options),
         {:ok, %{status: 200}} <- Req.get("http://127.0.0.1:#{port}/tests/state", options) do
      :ok
    else
      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          Mix.raise("Timed out waiting for QEMU HTTP readiness")
        end

        await_http(task, socket, port, deadline)
    end
  end

  defp run_session(ci?, socket, selection, port) do
    # erl reads ERL_EPMD_PORT into -epmd_port at VM startup, not at Node.start.
    # Reserve a candidate here; the child checks it again before QEMU binds it.
    {:ok, reservation} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, epmd_port} = :inet.port(reservation)
    :gen_tcp.close(reservation)

    # Nerves initialization needs argv before mix run consumes it.
    {_, status} =
      MuonTrap.cmd("mix", ["do", "compile", "+", "run", "--no-start", "dev/qemu_session.exs"],
        env: [
          {"MIX_TARGET", "host"},
          {"MIX_ENV",
           if ci? do
             "test"
           else
             "dev"
           end},
          {"ERL_EPMD_PORT", Integer.to_string(epmd_port)},
          {"NERVES_GATE_BACKEND_NODE", to_string(NervesGate.TestQemu.guest())},
          {"NERVES_GATE_DEVICE_NODE", nil},
          {"QEMU_HTTP_SOCKET", socket},
          {"QEMU_HTTP_PORT", Integer.to_string(port)},
          {"QEMU_CI", to_string(ci?)},
          {"QEMU_SCENARIO", selection}
        ],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    status
  end

  defp check_port!(port) do
    # Closed connections in TIME_WAIT are not a running server.
    case :gen_tcp.listen(port, ip: {127, 0, 0, 1}, reuseaddr: true) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, reason} ->
        Mix.raise(
          "Port #{port} unavailable: #{inspect(reason)}. Stop the existing server or use --port."
        )
    end
  end

  defp build_firmware! do
    {_, status} =
      MuonTrap.cmd("mix", ["firmware", "--overwrite"],
        env: [
          {"MIX_TARGET", "x86_64"},
          {"MIX_ENV", "dev"},
          {"NERVES_GATE_BACKEND_NODE", nil},
          {"NERVES_GATE_DEVICE_NODE", nil}
        ],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("QEMU firmware build failed")
  end
end

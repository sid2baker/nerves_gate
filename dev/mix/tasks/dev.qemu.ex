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

    unless System.find_executable("pasta"),
      do: Mix.raise("Install pasta (the passt package); see docs/development.md#prerequisites.")

    try do
      build_firmware!()
      IO.puts("Starting QEMU; waiting for the device and Phoenix...")

      status =
        if ci? do
          isolated(true, socket, options[:only] || "all")
        else
          serve(port, socket)
        end

      if status != 0, do: Mix.raise("Isolated QEMU session failed (exit #{status})")
    after
      File.rm(socket)
    end
  end

  defp options!(args) do
    {options, []} =
      OptionParser.parse!(args, strict: [port: :integer, ci: :boolean, only: :string])

    options
  end

  defp serve(port, socket) do
    {:ok, _} = Application.ensure_all_started(:req)
    task = Task.async(fn -> isolated(false, socket, "all") end)

    try do
      # Allow the guest's 180-second boot budget plus workstation Phoenix startup.
      await_http(task, socket, System.monotonic_time(:millisecond) + 240_000)
      proxy = proxy!(port, socket)

      try do
        IO.puts("QEMU ready: http://localhost:#{port}/tests")
        Task.await(task, :infinity)
      after
        GenServer.stop(proxy, :normal)
      end
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  defp await_http(task, socket, deadline) do
    case Task.yield(task, 100) do
      {:ok, status} -> Mix.raise("QEMU exited before HTTP was ready (exit #{status})")
      nil -> :ok
    end

    case Req.get("http://localhost/tests/state",
           unix_socket: socket,
           retry: false,
           redirect: false,
           connect_options: [timeout: 200],
           receive_timeout: 500
         ) do
      {:ok, %{status: 200}} ->
        :ok

      _ ->
        if System.monotonic_time(:millisecond) >= deadline,
          do: Mix.raise("Timed out waiting for QEMU HTTP readiness")

        await_http(task, socket, deadline)
    end
  end

  defp isolated(ci?, socket, selection) do
    # Pasta owns a new user/network namespace and outbound sockets, never host
    # routes or port forwards. A private mount namespace gives QEMU its own DNS.
    # Initialize Nerves before `mix run` replaces System.argv with an empty list.
    {_, status} =
      MuonTrap.cmd(
        "pasta",
        [
          "--foreground",
          "--config-net",
          "--ipv4-only",
          "--address",
          "192.0.2.2",
          "--netmask",
          "24",
          "--gateway",
          "192.0.2.1",
          "--ns-ifname",
          "ng-uplink",
          "--mtu",
          "1500",
          "--dns-forward",
          "192.0.2.3",
          "--no-map-gw",
          "--tcp-ports",
          "none",
          "--udp-ports",
          "none",
          "--tcp-ns",
          "none",
          "--udp-ns",
          "none",
          "--",
          "unshare",
          "--mount",
          "--propagation",
          "private",
          "mix",
          "do",
          "compile",
          "+",
          "run",
          "--no-start",
          "dev/qemu_session.exs"
        ],
        env: [
          {"MIX_TARGET", "host"},
          {"MIX_ENV", if(ci?, do: "test", else: "dev")},
          {"NERVES_GATE_BACKEND_NODE", "nerves_gate@192.168.77.2"},
          {"NERVES_GATE_DEVICE_NODE", nil},
          {"NERVES_GATE_HOST_NETNS", File.read_link!("/proc/self/ns/net")},
          {"NERVES_GATE_HOST_MNTNS", File.read_link!("/proc/self/ns/mnt")},
          {"QEMU_HTTP_SOCKET", socket},
          {"QEMU_CI", to_string(ci?)},
          {"QEMU_SCENARIO", selection}
        ],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    status
  end

  defp check_port!(port) do
    # Match socat's reuseaddr: closed connections in TIME_WAIT are not a running
    # server. An active listener still fails with :eaddrinuse.
    case :gen_tcp.listen(port, ip: {127, 0, 0, 1}, reuseaddr: true) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, reason} ->
        Mix.raise(
          "Port #{port} unavailable: #{inspect(reason)}. Stop the existing server or use --port."
        )
    end
  end

  defp proxy!(port, socket) do
    {:ok, pid} =
      MuonTrap.Daemon.start_link("socat", [
        "TCP-LISTEN:#{port},bind=127.0.0.1,reuseaddr,fork",
        "UNIX-CONNECT:#{socket}"
      ])

    pid
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

defmodule Mix.Tasks.Dev.Qemu do
  @moduledoc false
  use Mix.Task
  @shortdoc "Boot one disposable QEMU and its /tests page"

  @impl true
  def run(args) do
    {options, []} =
      OptionParser.parse!(args, strict: [port: :integer, ci: :boolean, only: :string])

    Mix.Task.run("compile")
    {:ok, _} = Application.ensure_all_started(:muontrap)

    dir =
      Path.expand(if options[:ci], do: "_build/qemu-ci-#{System.pid()}", else: "_build/qemu-dev")

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    lock = Path.join(dir, "session.lock")
    lock!(lock)
    socket = Path.join(dir, "http.sock")

    try do
      session(options, socket)
    after
      File.rm(socket)
      File.rm(lock)
    end
  end

  defp session(options, socket) do
    ci? = options[:ci] || false
    port = options[:port] || 4000
    unless ci?, do: check_port!(port)
    build_firmware!()
    proxy = unless ci?, do: proxy!(port, socket)

    try do
      IO.puts(if ci?, do: "Starting CI QEMU", else: "QEMU page: http://localhost:#{port}/tests")
      isolated(ci?, socket, options[:only] || "all")
    after
      stop_proxy(proxy)
    end
  end

  defp stop_proxy(nil), do: :ok
  defp stop_proxy(pid), do: GenServer.stop(pid, :normal)

  defp isolated(ci?, socket, selection) do
    {_, status} =
      MuonTrap.cmd(
        "unshare",
        [
          "--user",
          "--map-root-user",
          "--net",
          "mix",
          "do",
          "compile",
          "--force",
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
          {"QEMU_HTTP_SOCKET", socket},
          {"QEMU_CI", to_string(ci?)},
          {"QEMU_SCENARIO", selection}
        ],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    if status != 0, do: Mix.raise("QEMU session failed (exit #{status})")
  end

  defp lock!(path) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, file} ->
        File.close(file)

      {:error, _} ->
        Mix.raise(
          "QEMU session already owns #{path}. Stop it first; remove the lock only after a crash."
        )
    end
  end

  defp check_port!(port) do
    case :gen_tcp.listen(port, ip: {127, 0, 0, 1}) do
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
      System.cmd("mix", ["firmware", "--overwrite"],
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

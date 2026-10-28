defmodule Workbench.Launcher do
  @moduledoc """
  `mix dev` and explicit `mix scenario.ci` benches: flock → MuonTrap → one session BEAM
  running `priv/workbench/session.exs`. The OS wrapper owns the lock and child
  cleanup even if the session BEAM aborts.
  """

  def dev(args), do: launch(options!(args))

  def ci(selection, device, config \\ nil) do
    unless is_binary(device) and device != "" and Scenarios.select(selection) != [],
      do: Mix.raise("Select a QEMU scenario and explicit configured device")

    launch(ci: true, only: selection, device: device, config: config)
  end

  defp launch(options) do
    Simulator.Prerequisites.check!()
    ci? = options[:ci] || false
    port = options[:port] || if(ci?, do: 0, else: 4000)

    dir =
      Path.expand(if ci?, do: "_build/workbench-ci-#{System.pid()}", else: "_build/workbench")

    File.mkdir_p!(dir)
    File.chmod!(dir, 0o700)
    unless ci?, do: check_port!(port)
    flock = System.find_executable("flock") || Mix.raise("Install flock (util-linux)")
    config = config_path!(options, dir)

    if ci? do
      configured = Simulator.config(config, Path.join(dir, "preflight"))

      unless Enum.any?(Map.keys(configured.devices), &(to_string(&1) == options[:device])),
        do: Mix.raise("Unknown configured device #{options[:device]}; no devices started")
    end

    env = [
      {"MIX_TARGET", "host"},
      {"MIX_ENV", if(ci?, do: "test", else: "dev")},
      {"WORKBENCH_DIR", dir},
      {"WORKBENCH_HTTP_PORT", Integer.to_string(port)},
      {"WORKBENCH_CI", to_string(ci?)},
      {"WORKBENCH_SCENARIO", options[:only] || ""},
      {"WORKBENCH_DEVICE", options[:device] || ""},
      {"QEMU_SIM_CONFIG", config},
      {"NERVES_GATE_PLUGIN", options[:plugin] || ""},
      {"ERL_EPMD_PORT", false},
      {"NERVES_GATE_DEVICE_NODE", false}
    ]

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
          System.find_executable("mix"),
          "run",
          "--no-start",
          Workbench.script("session")
        ],
        env: Enum.map(env, fn {key, value} -> {~c"#{key}", value && ~c"#{value}"} end)
      ])

    status =
      try do
        output(port)
      after
        if Port.info(port), do: Port.close(port)
      end

    case status do
      0 -> :ok
      75 -> Mix.raise(Workbench.Session.conflict_message())
      _ -> Mix.raise("Workbench session failed (exit #{status})")
    end
  end

  defp output(port) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(data)
        MuonTrap.Port.report_bytes_handled(port, byte_size(data))
        output(port)

      {^port, {:exit_status, status}} ->
        status
    end
  end

  defp options!(args) do
    {options, plugins} =
      OptionParser.parse!(args,
        strict: [port: :integer, config: :string, firmware: :string]
      )

    if options[:config] && options[:firmware],
      do: Mix.raise("Use --config or --firmware, not both")

    if options[:port] && options[:port] not in 1..65_535,
      do: Mix.raise("Expected --port in 1..65535")

    case plugins do
      [] -> options
      [path] -> Keyword.put(options, :plugin, Workbench.Plugins.project!(path).path)
      _ -> Mix.raise("Usage: mix dev [PLUGIN_DIRECTORY] [--port PORT]")
    end
  end

  defp config_path!(options, dir) do
    cond do
      options[:config] ->
        Path.expand(options[:config])

      options[:firmware] ->
        firmware = Path.expand(options[:firmware])
        unless File.regular?(firmware), do: Mix.raise("Firmware file not found: #{firmware}")
        # Keep devices edited on the site; only the firmware image changes.
        path = Path.join(dir, "simulator.exs")

        config =
          if File.regular?(path),
            do: path |> Code.eval_file() |> elem(0),
            else: %{devices: %{gateway_a: %{network: %{internet: :lan1}}}}

        config = config |> Map.delete(:firmware_project) |> Map.put(:firmware, firmware)
        File.write!(path, [inspect(config, limit: :infinity), "\n"])
        path

      File.regular?(Path.join(Workbench.root(), "firmware/mix.exs")) ->
        Simulator.script("simulator")

      true ->
        Mix.raise("Supply --firmware path/to/nerves_gate.fw (a compatible QEMU firmware image)")
    end
  end

  defp check_port!(port) do
    case :gen_tcp.listen(port, ip: {127, 0, 0, 1}, reuseaddr: true) do
      {:ok, socket} ->
        :gen_tcp.close(socket)

      {:error, reason} ->
        Mix.raise(
          "Port #{port} unavailable: #{inspect(reason)}. Stop the existing server or use --port."
        )
    end
  end
end

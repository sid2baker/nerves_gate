defmodule Mix.Tasks.Qemu do
  @shortdoc "Runs and observes a local NervesGate QEMU topology"

  @moduledoc """
  Starts a fresh environment for commissioning (three machines by default):

      mix qemu setup
      mix qemu setup --count 5
      mix qemu add
      mix qemu remove M05

  Start, stop, and restart preserve current disks and settings slots. Reset
  recreates selected disks:

      mix qemu start
      mix qemu status
      mix qemu stop
      mix qemu restart
      mix qemu reset

  Inspect public runtime state from every local dashboard:

      mix qemu observe
      mix qemu observe M02
      mix qemu observe --json
      watch -n 2 mix qemu observe

  Follow the serial logs for all gateways or one gateway:

      mix qemu logs
      mix qemu logs M03
  """

  use Mix.Task

  @lifecycle ~w(start stop restart reset status prepare)

  alias NervesGateQEMU.Runner

  @impl Mix.Task
  def run(arguments) do
    case List.first(arguments) || "setup" do
      "setup" ->
        fresh_environment(Enum.drop(arguments, 1))

      "add" ->
        run!(&Runner.add/0)

      "remove" ->
        run!(fn -> Runner.remove(Enum.at(arguments, 1, "")) end)

      "observe" ->
        observe(Enum.drop(arguments, 1))

      "logs" ->
        logs(Enum.at(arguments, 1, "all"))

      action when action in @lifecycle ->
        lifecycle(action, Enum.at(arguments, 1, "all"))

      _other ->
        Mix.raise("expected setup, add, remove, observe, logs, or #{Enum.join(@lifecycle, ", ")}")
    end
  end

  defp fresh_environment(arguments) do
    count = setup_count(arguments)
    ensure_firmware!()
    run!(fn -> Runner.setup(count: count) end)
    ports = Enum.map_join(Runner.devices(), ", ", & &1.port)
    Mix.shell().info("Fresh commissioning pages ready on ports #{ports} at /commissioning")
  end

  defp lifecycle("status", target) do
    selected_nodes!(target)
    |> Enum.each(fn {node, _port} ->
      state = NervesGateQEMU.Fault.vm_state(device!(node))
      Mix.shell().info("#{node} #{state}")
    end)
  end

  defp lifecycle("prepare", target) do
    ensure_firmware!()
    run_script_compatibility("prepare", target)
  end

  defp lifecycle(action, target) do
    if action in ["start", "restart", "reset"], do: ensure_firmware!()
    runner = String.to_existing_atom(action)
    selected = if target == "all", do: :all, else: target
    run!(fn -> apply(Runner, runner, [selected]) end)
  end

  defp observe(arguments) do
    target = Enum.find(arguments, "all", &(not String.starts_with?(&1, "--")))
    json? = "--json" in arguments
    {:ok, _applications} = Application.ensure_all_started(:inets)

    nodes = selected_nodes!(target)

    if json?, do: print_json(nodes), else: Enum.each(nodes, &observe_node/1)
  end

  defp print_json(nodes) do
    snapshots = Map.new(nodes, &json_snapshot/1)
    Mix.shell().info(Jason.encode!(snapshots, pretty: true))
  end

  defp json_snapshot({node, port}) do
    value =
      case fetch_status(status_url(port)) do
        {:ok, status} -> status
        {:error, reason} -> %{"error" => format_value(reason)}
      end

    {node, value}
  end

  defp observe_node({node, port}) do
    url = status_url(port)

    case fetch_status(url) do
      {:ok, status} ->
        print_summary(node, url, status)

      {:error, reason} ->
        Mix.shell().error("#{node} #{url}\n  unavailable: #{format_value(reason)}")
    end
  end

  defp status_url(port), do: "http://127.0.0.1:#{port}/api/status"

  defp fetch_status(url) do
    request = {String.to_charlist(url), []}
    http_options = [timeout: 3_000, connect_timeout: 3_000]

    case :httpc.request(:get, request, http_options, body_format: :binary) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        Jason.decode(body)

      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:error, "HTTP #{status}: #{String.trim(body)}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp print_summary(node, url, %{"schema" => "nerves_gate.status.v1"} = status) do
    configuration = Map.get(status, "configuration", %{})
    data = status |> get_in(["local", "data"]) |> value_map()
    internet = Map.get(data, "internet", %{})
    tailnet = Map.get(data, "tailnet", %{})
    cluster = Map.get(data, "cluster", %{})
    tailnet_health = status |> get_in(["runtime", "tailscale"]) |> value_map()
    replicas = status |> Map.get("replicas") |> value_map()
    candidates = status |> get_in(["runtime", "cluster", "candidates"]) |> value_list()
    alarms = Map.get(data, "alarms", [])

    connected_replicas = Enum.count(replicas, fn {_id, replica} -> replica["connected"] end)
    stale_replicas = map_size(replicas) - connected_replicas
    pending = configuration |> Map.get("change") |> pending_phase()

    Mix.shell().info("""
    #{node} #{url}
      configured=#{configuration["configured"]} pending=#{pending}
      internet=#{online_state(internet)} tailnet=#{online_state(tailnet)} #{tailnet["ipv4"] || "no-ip"} daemon=#{tailnet_health["daemon"] || "unknown"} socket=#{tailnet_health["socket"] || "unknown"}
      cluster=#{online_state(cluster)} group=#{cluster["group"] || "disabled"} connected=#{length(Map.get(cluster, "connected", []))}
      replicas=#{map_size(replicas)} connected=#{connected_replicas} stale=#{stale_replicas}
    #{format_candidates(candidates)}#{format_alarms(alarms)}
    """)
  end

  defp print_summary(node, url, _unsupported) do
    Mix.shell().error("#{node} #{url}\n  unavailable: unsupported status schema")
  end

  defp format_candidates([]), do: "  candidates=none\n"

  defp format_candidates(candidates) do
    lines =
      Enum.map_join(candidates, "\n", fn candidate ->
        discovery =
          if candidate["discovered"],
            do: candidate["group"] || "no-group",
            else: "error:#{format_value(candidate["discovery_error"])}"

        connection = if candidate["connected"], do: "connected", else: "disconnected"

        "    #{candidate["hostname"] || "unknown"} #{candidate["ipv4"] || "no-ip"} discovery=#{discovery} #{connection}"
      end)

    "  candidates:\n#{lines}\n"
  end

  defp format_alarms([]), do: "  alarms=none"

  defp format_alarms(alarms) do
    ids = Enum.map_join(alarms, ", ", &Map.get(&1, "id", "unknown"))
    "  alarms=#{ids}"
  end

  defp pending_phase(nil), do: "none"
  defp pending_phase(pending), do: Map.get(pending, "phase", "unknown")

  defp online_state(%{"status" => "online"}), do: "online"

  defp online_state(%{"status" => status})
       when status in ["offline", "failed", "blocked", "disabled"],
       do: "offline"

  defp online_state(_status), do: "unknown"

  defp value_map(value) when is_map(value), do: value
  defp value_map(_value), do: %{}

  defp value_list(value) when is_list(value), do: value
  defp value_list(_value), do: []

  defp format_value(nil), do: "unknown"
  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: inspect(value)

  defp logs(target) do
    paths =
      Enum.map(selected_nodes!(target), fn {node, _port} -> qemu_path("#{node}.serial.log") end)

    executable = System.find_executable("tail") || Mix.raise("tail executable not found")

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-n", "100", "-F" | paths]
      ])

    encoding = Keyword.fetch!(:io.getopts(:standard_io), :encoding)
    :ok = :io.setopts(:standard_io, encoding: :latin1)

    try do
      stream_log_port(port)
    after
      :io.setopts(:standard_io, encoding: encoding)
    end
  end

  defp stream_log_port(port) do
    receive do
      {^port, {:data, data}} ->
        IO.binwrite(:stdio, data)
        stream_log_port(port)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, status}} ->
        Mix.raise("tail failed with status #{status}")
    end
  end

  defp selected_nodes!("all"),
    do: Enum.map(Runner.devices(), &{&1.id, &1.port})

  defp selected_nodes!(target) do
    target = String.upcase(target)

    case Enum.find(Runner.devices(), &(&1.id == target)) do
      nil -> Mix.raise("expected an active QEMU device or all")
      device -> [{device.id, device.port}]
    end
  end

  defp device!(id) do
    Enum.find(Runner.devices(), &(&1.id == id)) || Mix.raise("QEMU device not found: #{id}")
  end

  defp run_script_compatibility(action, target) do
    nodes = Runner.devices()
    environment = [{"NERVES_GATE_QEMU_NODES", Enum.map_join(nodes, " ", & &1.id)}]
    script = Path.join(Runner.project_root(), "scripts/qemu.sh")

    case System.cmd(script, [action, target],
           env: environment,
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("QEMU command failed with status #{status}")
    end
  end

  defp run!(function) do
    case function.() do
      :ok -> :ok
      {:ok, value} -> Mix.shell().info(inspect(value))
      {:error, reason} -> Mix.raise("QEMU operation failed: #{inspect(reason)}")
    end
  end

  defp setup_count(arguments) do
    case arguments do
      ["--count", count] -> parse_count!(count)
      ["--count=" <> count] -> parse_count!(count)
      [] -> 3
      _other -> Mix.raise("usage: mix qemu setup [--count N]")
    end
  end

  defp parse_count!(count) do
    case Integer.parse(count) do
      {value, ""} when value in 1..12 -> value
      _invalid -> Mix.raise("QEMU machine count must be between 1 and 12")
    end
  end

  defp qemu_path(file), do: Path.join(Runner.state_root(), file)

  defp ensure_firmware! do
    firmware = Runner.firmware_path()

    unless File.exists?(firmware) do
      Mix.shell().info("Building x86_64 firmware first…")

      case System.cmd("mix", ["firmware"],
             cd: Runner.project_root(),
             env: [{"MIX_TARGET", "x86_64"}],
             into: IO.stream(),
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {_output, status} -> Mix.raise("firmware build failed with status #{status}")
      end
    end
  end
end

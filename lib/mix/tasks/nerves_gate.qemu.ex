defmodule Mix.Tasks.NervesGate.Qemu do
  @shortdoc "Runs and observes the three-node NervesGate QEMU environment"

  @moduledoc """
  Starts a fresh three-node environment for commissioning:

      mix nerves_gate.qemu setup

  Lifecycle commands preserve the current disks and settings slots:

      mix nerves_gate.qemu start
      mix nerves_gate.qemu status
      mix nerves_gate.qemu stop
      mix nerves_gate.qemu restart
      mix nerves_gate.qemu reset

  Inspect public runtime state from every local dashboard:

      mix nerves_gate.qemu observe
      mix nerves_gate.qemu observe M02
      mix nerves_gate.qemu observe --json
      watch -n 2 mix nerves_gate.qemu observe

  Follow the serial logs for all gateways or one gateway:

      mix nerves_gate.qemu logs
      mix nerves_gate.qemu logs M03
  """

  use Mix.Task

  @lifecycle ~w(start stop restart reset status prepare)
  @nodes [{"M01", 4001}, {"M02", 4002}, {"M03", 4003}]

  @impl Mix.Task
  def run(arguments) do
    case List.first(arguments) || "setup" do
      "setup" -> fresh_environment()
      "observe" -> observe(Enum.drop(arguments, 1))
      "logs" -> logs(Enum.at(arguments, 1, "all"))
      action when action in @lifecycle -> lifecycle(action, Enum.at(arguments, 1, "all"))
      _other -> Mix.raise("expected setup, observe, logs, or #{Enum.join(@lifecycle, ", ")}")
    end
  end

  defp fresh_environment do
    ensure_firmware!()
    run_script("reset", "all")
    run_script("start", "all")
    Mix.shell().info("Fresh commissioning pages ready on ports 4001–4003 at /commissioning")
  end

  defp lifecycle(action, target) do
    if action in ["start", "restart", "prepare", "reset"], do: ensure_firmware!()
    run_script(action, target)
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

  defp print_summary(node, url, status) do
    configuration = Map.get(status, "configuration", %{})
    internet = Map.get(status, "network", %{}) |> Map.get("connectivity", %{})
    tailnet = Map.get(status, "tailnet", %{})
    tailnet_health = Map.get(tailnet, "health") || %{}
    cluster = Map.get(status, "cluster", %{})
    replicas = status |> get_in(["device_state", "replicas"]) |> value_map()
    candidates = Map.get(cluster, "candidates", [])
    alarms = Map.get(status, "alarms", [])

    connected_replicas = Enum.count(replicas, fn {_id, replica} -> replica["connected"] end)
    stale_replicas = map_size(replicas) - connected_replicas
    pending = configuration |> Map.get("pending") |> pending_phase()

    Mix.shell().info("""
    #{node} #{url}
      configured=#{configuration["configured"]} pending=#{pending}
      internet=#{online_state(internet)} tailnet=#{online_state(tailnet)} #{tailnet["ipv4"] || "no-ip"} daemon=#{tailnet_health["daemon"] || "unknown"} socket=#{tailnet_health["socket"] || "unknown"}
      cluster=#{online_state(cluster)} group=#{cluster["group"] || "disabled"} connected=#{length(Map.get(cluster, "connected", []))}
      replicas=#{map_size(replicas)} connected=#{connected_replicas} stale=#{stale_replicas}
    #{format_candidates(candidates)}#{format_alarms(alarms)}
    """)
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

  defp online_state(%{"online" => true}), do: "online"
  defp online_state(%{"online" => false}), do: "offline"
  defp online_state(_status), do: "unknown"

  defp value_map(value) when is_map(value), do: value
  defp value_map(_value), do: %{}

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

  defp selected_nodes!("all"), do: @nodes

  defp selected_nodes!(target) do
    case Enum.find(@nodes, fn {node, _port} -> node == target end) do
      nil -> Mix.raise("expected M01, M02, M03, or all")
      node -> [node]
    end
  end

  defp run_script(action, target) do
    script = Path.expand("scripts/three_node_qemu.sh")

    case System.cmd(script, [action, target], into: IO.stream(), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("QEMU command failed with status #{status}")
    end
  end

  defp qemu_path(file) do
    root = System.get_env("NERVES_GATE_QEMU_STATE", Path.expand("tmp/qemu"))
    Path.join(root, file)
  end

  defp ensure_firmware! do
    firmware = Path.expand("_build/x86_64_dev/nerves/images/nerves_gate.fw")

    unless File.exists?(firmware) do
      Mix.shell().info("Building x86_64 firmware first…")

      case System.cmd("mix", ["firmware"],
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

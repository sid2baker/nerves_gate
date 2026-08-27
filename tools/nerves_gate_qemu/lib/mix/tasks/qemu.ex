defmodule Mix.Tasks.Qemu do
  @shortdoc "Runs and observes a local NervesGate QEMU topology"

  @usage """
  Usage:
    mix qemu setup [--count N] [--rebuild]
    mix qemu add
    mix qemu remove DEVICE
    mix qemu commission [--group GROUP]
    mix qemu integration [--count N] [--rebuild] [--group GROUP]
    mix qemu start|stop|restart|reset [DEVICE|all]
    mix qemu status [DEVICE|all]
    mix qemu observe [DEVICE|all] [--json]
    mix qemu logs [DEVICE|all]
    mix qemu prepare [DEVICE|all]
    mix qemu help

  With no command, `setup --count 3` is used. Pass `--rebuild` to build current
  source before recreating every disk. Start, stop, and restart preserve disks.
  """

  @moduledoc """
  Runs and observes a local NervesGate QEMU topology.

  #{@usage}
  """

  use Mix.Task

  @lifecycle ~w(start stop restart reset status prepare)
  @help_arguments ~w(help --help -h)

  alias NervesGateQEMU.{Environment, Harness, Runner}

  @impl Mix.Task
  def run(arguments), do: dispatch(List.first(arguments) || "setup", arguments)

  defp dispatch(help, _arguments) when help in @help_arguments,
    do: Mix.shell().info(@usage)

  defp dispatch("setup", arguments), do: fresh_environment(Enum.drop(arguments, 1))
  defp dispatch("add", _arguments), do: run!(&Runner.add/0)
  defp dispatch("remove", arguments), do: run!(fn -> Runner.remove(Enum.at(arguments, 1, "")) end)
  defp dispatch("observe", arguments), do: observe(Enum.drop(arguments, 1))
  defp dispatch("logs", arguments), do: logs(Enum.at(arguments, 1, "all"))
  defp dispatch("commission", arguments), do: commission(Enum.drop(arguments, 1))
  defp dispatch("integration", arguments), do: integration(Enum.drop(arguments, 1))

  defp dispatch(action, arguments) when action in @lifecycle,
    do: lifecycle(action, Enum.at(arguments, 1, "all"))

  defp dispatch(other, _arguments),
    do: Mix.raise("unknown QEMU command #{inspect(other)}; run `mix qemu help` for usage")

  defp fresh_environment(arguments) do
    {count, rebuild?} = setup_options(arguments)
    if rebuild?, do: build_firmware!(), else: ensure_firmware!()
    run!(fn -> Runner.setup(count: count) end)
    ports = Enum.map_join(Runner.devices(), ", ", & &1.port)
    Mix.shell().info("Fresh commissioning pages ready on ports #{ports} at /commissioning")
  end

  defp commission(arguments) do
    group = group_option!(arguments, "usage: mix qemu commission [--group GROUP]")
    {:ok, _applications} = Application.ensure_all_started(:inets)
    Harness.ensure_cluster!(count: length(Runner.devices()), group: group)
    Mix.shell().info("QEMU gateways are commissioned and fully connected in #{group}")
  end

  defp integration(arguments) do
    {count, rebuild?, group} = integration_options!(arguments)

    if rebuild? do
      build_release_fixture!()
      build_firmware!()
    else
      ensure_firmware!()
      ensure_release_fixture!()
    end

    # Every integration run starts from newly provisioned known-good disks.
    # Firmware transactions intentionally survive VM restarts, so reusing disks
    # here would leak the previous run's staged artifact or trial journal.
    run!(fn -> Runner.setup(count: count) end)

    {:ok, _applications} = Application.ensure_all_started(:inets)
    Harness.ensure_cluster!(count: count, group: group)
    run_integration_tests!()
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

  defp print_summary(node, url, %{"schema" => "nerves_gate.status.v3"} = status) do
    state = status |> get_in(["local", "state"]) |> value_map()
    configuration = state |> Map.get("configuration") |> value_map()
    internet = state |> Map.get("internet") |> value_map()
    tailnet = state |> Map.get("tailnet") |> value_map()
    cluster = state |> Map.get("cluster") |> value_map()
    tailnet_health = tailnet |> Map.get("health") |> value_map()
    replicas = status |> Map.get("replicas") |> value_map()
    candidates = cluster |> Map.get("candidates") |> value_list()
    alarms = Map.get(state, "alarms", [])

    connected_replicas = Enum.count(replicas, fn {_id, replica} -> replica["connected"] end)
    stale_replicas = map_size(replicas) - connected_replicas
    pending = configuration |> Map.get("pending") |> pending_phase()

    Mix.shell().info("""
    #{node} #{url}
      configured=#{configuration["configured"]} pending=#{pending}
      internet=#{layer_state(internet)} tailnet=#{layer_state(tailnet)} #{tailnet["ipv4"] || "no-ip"} daemon=#{tailnet_health["daemon"] || "unknown"} socket=#{tailnet_health["socket"] || "unknown"}
      cluster=#{layer_state(cluster)} group=#{cluster["group"] || "disabled"} connected=#{length(Map.get(cluster, "connected", []))}
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

  defp layer_state(%{"state" => state}) when is_binary(state), do: state
  defp layer_state(_status), do: "unknown"

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

  defp group_option!(arguments, usage) do
    case OptionParser.parse(arguments, strict: [group: :string]) do
      {options, [], []} -> Keyword.get(options, :group, Environment.cluster_group())
      _invalid -> Mix.raise(usage)
    end
  end

  defp integration_options!(arguments) do
    case OptionParser.parse(arguments,
           strict: [count: :integer, rebuild: :boolean, group: :string]
         ) do
      {options, [], []} ->
        count = Keyword.get(options, :count, 3)

        if count in 3..12 do
          {
            count,
            Keyword.get(options, :rebuild, false),
            Keyword.get(options, :group, Environment.cluster_group())
          }
        else
          Mix.raise("QEMU integration machine count must be between 3 and 12")
        end

      _invalid ->
        Mix.raise("usage: mix qemu integration [--count N] [--rebuild] [--group GROUP]")
    end
  end

  defp run_integration_tests! do
    case System.cmd(
           "mix",
           ["test", "--include", "integration", "test/integration"],
           cd: File.cwd!(),
           env: [{"MIX_ENV", "test"}],
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("QEMU integration tests failed with status #{status}")
    end
  end

  defp setup_options(arguments) do
    case OptionParser.parse(arguments, strict: [count: :integer, rebuild: :boolean]) do
      {options, [], []} ->
        count = Keyword.get(options, :count, 3)

        if count in 1..12,
          do: {count, Keyword.get(options, :rebuild, false)},
          else: Mix.raise("QEMU machine count must be between 1 and 12")

      _invalid ->
        Mix.raise("usage: mix qemu setup [--count N] [--rebuild]")
    end
  end

  defp qemu_path(file), do: Path.join(Runner.state_root(), file)

  defp ensure_firmware! do
    unless File.exists?(Runner.firmware_path()), do: build_firmware!()
  end

  defp ensure_release_fixture! do
    required = ["index-0.2.0.json", "index-0.3.0.json", "index-wrong.json"]

    unless Enum.all?(required, &File.regular?(Path.join(Runner.release_root(), &1))) do
      Mix.raise("signed firmware fixtures are missing; rerun integration with --rebuild")
    end
  end

  defp build_firmware! do
    firmware = Runner.firmware_path()
    File.mkdir_p!(Path.dirname(firmware))
    Mix.shell().info("Building current x86_64 firmware at #{firmware}…")
    build_project_firmware!(firmware, "0.1.0")
  end

  defp build_release_fixture! do
    root = Runner.release_root()

    private_key =
      Path.join(
        Runner.project_root(),
        "tools/nerves_gate_qemu/fixtures/firmware/qemu-fwup-key.priv"
      )

    File.rm_rf!(root)
    File.mkdir_p!(root)

    Enum.each(["0.2.0", "0.3.0"], fn version ->
      unsigned = Path.join(root, "candidate-#{version}-unsigned.fw")
      Mix.shell().info("Building signed QEMU update fixture #{version}…")
      build_project_firmware!(unsigned, version)

      run_project_mix!(
        [
          "nerves_gate.firmware.release",
          "--firmware",
          unsigned,
          "--output",
          root,
          "--private-key-file",
          private_key
        ],
        firmware_environment(version)
      )

      File.rm!(unsigned)
      write_release_index!(root, version)
    end)

    write_wrong_metadata_index!(root, private_key)
    File.cp!(Path.join(root, "index-0.2.0.json"), Path.join(root, "index.json"))
  end

  defp build_project_firmware!(output, version) do
    run_project_mix!(["clean"], firmware_environment(version))
    run_project_mix!(["firmware", "--output", output], firmware_environment(version))
  end

  defp run_project_mix!(arguments, environment) do
    case System.cmd("mix", arguments,
           cd: Runner.project_root(),
           env: environment,
           into: IO.stream(),
           stderr_to_stdout: true
         ) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("project mix command failed with status #{status}")
    end
  end

  defp firmware_environment(version) do
    public_key =
      Runner.project_root()
      |> Path.join("tools/nerves_gate_qemu/fixtures/firmware/qemu-fwup-key.pub")
      |> File.read!()
      |> String.trim()

    [
      {"MIX_TARGET", "x86_64"},
      {"NERVES_GATE_VERSION", version},
      {"NERVES_FW_VCS_IDENTIFIER", source_revision()},
      {"NERVES_GATE_RELEASE_API_URL", "http://10.0.2.2:4010"},
      {"NERVES_GATE_FWUP_PUBLIC_KEYS", public_key},
      {"NERVES_GATE_TRIAL_TIMEOUT_MS", "300000"},
      {"NERVES_GATE_STABLE_WINDOW_MS", "2000"},
      {"NERVES_GATE_HEALTH_GRACE_MS", "180000"}
    ]
  end

  defp source_revision do
    case System.cmd("git", ["rev-parse", "HEAD"], cd: Runner.project_root()) do
      {revision, 0} -> String.trim(revision)
      _failure -> "qemu-fixture"
    end
  end

  defp write_wrong_metadata_index!(root, private_key_path) do
    [source] = Path.wildcard(Path.join(root, "*-0.2.0-*.firmware.json"))
    manifest = source |> File.read!() |> Jason.decode!() |> Map.put("system", "wrong_system")
    path = Path.join(root, "wrong-system.firmware.json")
    contents = Jason.encode!(manifest, pretty: true) <> "\n"

    private_key = private_key_path |> File.read!() |> String.trim() |> Base.decode64!()

    signature =
      :crypto.sign(:eddsa, :none, contents, [binary_part(private_key, 0, 32), :ed25519])

    File.write!(path, contents)
    File.write!(path <> ".sig", Base.encode64(signature))
    write_release_index_for_manifest!(root, path, "index-wrong.json")
  end

  defp write_release_index!(root, version) do
    [manifest_path] = Path.wildcard(Path.join(root, "*-#{version}-*.firmware.json"))
    write_release_index_for_manifest!(root, manifest_path, "index-#{version}.json")
  end

  defp write_release_index_for_manifest!(root, manifest_path, index_name) do
    manifest = manifest_path |> File.read!() |> Jason.decode!()
    manifest_name = Path.basename(manifest_path)
    artifact_name = Map.fetch!(manifest, "artifact")
    base = "http://10.0.2.2:4010/assets"

    release = %{
      "draft" => false,
      "prerelease" => false,
      "published_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "assets" => [
        %{"name" => manifest_name, "browser_download_url" => "#{base}/#{manifest_name}"},
        %{
          "name" => manifest_name <> ".sig",
          "browser_download_url" => "#{base}/#{manifest_name}.sig"
        },
        %{"name" => artifact_name, "browser_download_url" => "#{base}/#{artifact_name}"}
      ]
    }

    File.write!(Path.join(root, index_name), Jason.encode!([release], pretty: true))
  end
end

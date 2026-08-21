defmodule Mix.Tasks.NervesGate.Qemu do
  @shortdoc "Runs the three-node NervesGate QEMU environment"

  @moduledoc """
  Runs one of two fresh three-node environments:

      mix nerves_gate.qemu setup
      mix nerves_gate.qemu functional

  `setup` stops after boot so every initialization step can be tested manually.
  `functional` reads `NERVES_GATE_TAILSCALE_AUTH_KEY` from `.env`, configures
  DHCP, enrolls Tailscale, and starts the cluster on all three nodes.

  Lifecycle commands preserve the current disks:

      mix nerves_gate.qemu status
      mix nerves_gate.qemu stop
      mix nerves_gate.qemu restart
      mix nerves_gate.qemu reset
  """

  use Mix.Task

  @lifecycle ~w(start stop restart reset status prepare)
  @nodes [{"M01", 4001}, {"M02", 4002}, {"M03", 4003}]

  @impl Mix.Task
  def run(arguments) do
    load_dotenv()

    case List.first(arguments) || "setup" do
      "setup" -> fresh_environment(false)
      "functional" -> fresh_environment(true)
      action when action in @lifecycle -> lifecycle(action, Enum.at(arguments, 1, "all"))
      _other -> Mix.raise("expected setup, functional, #{Enum.join(@lifecycle, ", ")}")
    end
  end

  defp fresh_environment(functional?) do
    ensure_firmware!()
    run_script("reset", "all")
    run_script("start", "all")

    if functional? do
      key = System.get_env("NERVES_GATE_TAILSCALE_AUTH_KEY")

      unless is_binary(key) and byte_size(key) >= 8 do
        run_script("stop", "all")
        Mix.raise("NERVES_GATE_TAILSCALE_AUTH_KEY is missing from .env")
      end

      commission_all(key)
    else
      Mix.shell().info("Fresh setup environment ready at http://127.0.0.1:4001 through :4003")
    end
  end

  defp lifecycle(action, target) do
    if action in ["start", "restart", "prepare", "reset"], do: ensure_firmware!()
    run_script(action, target)
  end

  defp commission_all(key) do
    Application.ensure_all_started(:inets)
    Application.ensure_all_started(:ssl)

    results =
      Task.async_stream(
        @nodes,
        fn node -> commission(node, key) end,
        timeout: 180_000,
        ordered: true
      )
      |> Enum.to_list()

    dashboards =
      for {:ok, {node, ipv4}} <- results,
          is_binary(node) and is_binary(ipv4),
          do: {node, ipv4}

    if length(dashboards) == length(@nodes) do
      Enum.each(dashboards, fn {node, ipv4} ->
        save_tailnet_ip(node, ipv4)
        Mix.shell().info("#{node} dashboard (tailnet only): http://#{ipv4}/")
      end)

      Mix.shell().info("All three gateways reached functional mode.")
      Mix.shell().info("The localhost setup forwards close after commissioning.")
    else
      run_script("stop", "all")
      Mix.raise("functional QEMU setup failed")
    end
  end

  defp commission({node, port}, key) do
    base = "http://127.0.0.1:#{port}"
    Mix.shell().info("#{node}: waiting for setup")
    :ok = wait_for_setup(base, 120)
    :ok = post(base <> "/api/setup/internet", %{"ip_address" => "dhcp"}, 45_000)
    Mix.shell().info("#{node}: Internet verified")
    :ok = retry_tailscale(base, key, 15)
    ipv4 = tailnet_ipv4(base, 5)
    Mix.shell().info("#{node}: Tailscale connected")
    :ok = retry_cluster(base, 60)
    Mix.shell().info("#{node}: cluster started")
    {node, ipv4}
  rescue
    _error -> {:error, node}
  catch
    _kind, _reason -> {:error, node}
  end

  defp wait_for_setup(_base, 0), do: raise("setup timeout")

  defp wait_for_setup(base, attempts) do
    case request(:get, base <> "/", nil, 2_000) do
      {:ok, 200, _body} ->
        :ok

      _unavailable ->
        Process.sleep(1_000)
        wait_for_setup(base, attempts - 1)
    end
  end

  defp retry_tailscale(_base, _key, 0), do: raise("Tailscale timeout")

  defp retry_tailscale(base, key, attempts) do
    case post(base <> "/api/setup/tailscale", %{"auth_token" => key}, 30_000) do
      :ok ->
        :ok

      {:error, _status} ->
        Process.sleep(1_000)
        retry_tailscale(base, key, attempts - 1)
    end
  end

  defp tailnet_ipv4(_base, 0), do: raise("Tailscale IP timeout")

  defp tailnet_ipv4(base, attempts) do
    with {:ok, 200, body} <- request(:get, base <> "/api/setup/status", nil, 2_000),
         {:ok, status} <- Jason.decode(body),
         ipv4 when is_binary(ipv4) <- get_in(status, ["tailnet", "ipv4"]) do
      ipv4
    else
      _unavailable ->
        Process.sleep(500)
        tailnet_ipv4(base, attempts - 1)
    end
  end

  defp retry_cluster(_base, 0), do: raise("cluster timeout")

  defp retry_cluster(base, attempts) do
    case post(base <> "/api/setup/cluster", %{}, 10_000) do
      :ok ->
        :ok

      {:error, _status} ->
        Process.sleep(1_000)
        retry_cluster(base, attempts - 1)
    end
  end

  defp post(url, params, timeout) do
    case request(:post, url, URI.encode_query(params), timeout) do
      {:ok, status, _body} when status in 200..299 -> :ok
      {:ok, status, _body} -> {:error, status}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(:get, url, _body, timeout) do
    options = [timeout: timeout, connect_timeout: timeout]

    case :httpc.request(:get, {String.to_charlist(url), []}, options, body_format: :binary) do
      {:ok, {{_http, status, _message}, _headers, response}} -> {:ok, status, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(:post, url, body, timeout) do
    headers = [{~c"accept", ~c"application/json"}]
    request = {String.to_charlist(url), headers, ~c"application/x-www-form-urlencoded", body}
    options = [timeout: timeout, connect_timeout: timeout]

    case :httpc.request(:post, request, options, body_format: :binary) do
      {:ok, {{_http, status, _message}, _headers, response}} -> {:ok, status, response}
      {:error, reason} -> {:error, reason}
    end
  end

  defp save_tailnet_ip(node, ipv4) do
    state = System.get_env("NERVES_GATE_QEMU_STATE", Path.expand("tmp/qemu"))
    File.mkdir_p!(state)
    File.write!(Path.join(state, "#{node}.tailnet-ip"), ipv4 <> "\n")
  end

  defp load_dotenv do
    path = Path.expand(".env")

    if File.regular?(path) do
      path
      |> File.stream!()
      |> Enum.each(&load_env_line/1)
    end
  end

  defp load_env_line(line) do
    line = String.trim(line)

    with false <- line == "" or String.starts_with?(line, "#"),
         [key, value] <- String.split(line, "=", parts: 2),
         key <- key |> String.trim() |> String.trim_leading("export "),
         true <- String.match?(key, ~r/^[A-Z_][A-Z0-9_]*$/),
         nil <- System.get_env(key) do
      System.put_env(key, unquote_value(String.trim(value)))
    else
      _ignored -> :ok
    end
  end

  defp unquote_value(<<quote, rest::binary>>) when quote in [?", ?'] do
    if String.ends_with?(rest, <<quote>>),
      do: binary_part(rest, 0, byte_size(rest) - 1),
      else: rest
  end

  defp unquote_value(value), do: value

  defp run_script(action, target) do
    script = Path.expand("scripts/three_node_qemu.sh")

    case System.cmd(script, [action, target], into: IO.stream(), stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {_output, status} -> Mix.raise("QEMU command failed with status #{status}")
    end
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

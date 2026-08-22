defmodule NervesGate.Cluster.Distribution do
  @moduledoc "Small, local boundary around EPMD and distributed Erlang on the Tailscale IPv4."

  @spec start(String.t(), atom()) :: {:ok, node()} | {:error, term()}
  def start(ipv4, cookie) when is_binary(ipv4) and is_atom(cookie) do
    with {:ok, address, canonical_ipv4} <- parse_ipv4(ipv4),
         :ok <- configure_distribution(address),
         :ok <- ensure_epmd(canonical_ipv4),
         {:ok, node_name} <- start_net_kernel(canonical_ipv4) do
      Node.set_cookie(cookie)
      :net_kernel.monitor_nodes(true, node_type: :visible, nodedown_reason: true)
      {:ok, node_name}
    else
      {:error, reason} -> cleanup_error(reason)
    end
  end

  @spec stop() :: :ok | {:error, term()}
  def stop do
    Enum.each(Node.list(:connected), &Node.disconnect/1)

    result = if Node.alive?(), do: :net_kernel.stop(), else: :ok

    if result == :ok, do: stop_epmd()
    result
  end

  @spec connected() :: [node()]
  def connected, do: Node.list(:connected)

  @spec alive?() :: boolean()
  def alive?, do: Node.alive?()

  defp parse_ipv4(ipv4) do
    case :inet.parse_ipv4_address(String.to_charlist(ipv4)) do
      {:ok, {_a, _b, _c, _d} = address} ->
        {:ok, address, address |> :inet.ntoa() |> List.to_string()}

      {:error, :einval} ->
        {:error, :invalid_tailscale_ipv4}
    end
  end

  defp configure_distribution(address) do
    port = Application.fetch_env!(:nerves_gate, :distribution_port)
    Application.put_env(:kernel, :inet_dist_listen_min, port, persistent: true)
    Application.put_env(:kernel, :inet_dist_listen_max, port, persistent: true)
    Application.put_env(:kernel, :inet_dist_use_interface, address, persistent: true)
    :ok
  end

  defp ensure_epmd(ipv4) do
    System.put_env("ERL_EPMD_ADDRESS", ipv4)

    case run_epmd(["-daemon"]) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:epmd, reason}}
    end
  end

  defp start_net_kernel(ipv4) do
    # The address is canonicalized before this trusted local node name is made.
    node_name = String.to_atom("nervesgate@#{ipv4}")

    case :net_kernel.start(node_name, %{name_domain: :longnames}) do
      {:ok, _pid} -> {:ok, node_name}
      {:error, {:already_started, _pid}} when node() == node_name -> {:ok, node_name}
      {:error, {:already_started, _pid}} -> {:error, :distribution_already_started}
      {:error, reason} -> {:error, reason}
    end
  end

  defp cleanup_error(reason) do
    stop()
    {:error, reason}
  end

  defp stop_epmd do
    case run_epmd(["-kill"]) do
      {:ok, _output} -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp run_epmd(arguments) do
    case System.find_executable("epmd") do
      nil ->
        {:error, :not_found}

      path ->
        case MuonTrap.cmd(path, arguments, stderr_to_stdout: true, timeout: 2_000) do
          {output, 0} -> {:ok, String.trim(output)}
          {_output, :timeout} -> {:error, :timeout}
          {output, code} -> {:error, {:exit, code, String.slice(String.trim(output), 0, 512)}}
        end
    end
  end
end

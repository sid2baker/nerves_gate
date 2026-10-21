defmodule NervesGateSim.DevDiscovery do
  @moduledoc false

  @probe_timeout 2_000

  # Read the existing daemon only. Never start or configure workstation Tailscale.
  def tailnet do
    {:ok, _} = Application.ensure_all_started(:req)

    case Req.get("http://local-tailscaled.sock/localapi/v0/status",
           unix_socket: "/var/run/tailscale/tailscaled.sock",
           headers: [{"host", "local-tailscaled.sock"}],
           retry: false,
           redirect: false,
           connect_options: [timeout: 3_000],
           receive_timeout: 3_000
         ) do
      {:ok, %{status: 200, body: %{"BackendState" => "Running"} = status}} ->
        tailnet_addresses(status)

      {:ok, %{status: 200}} ->
        {:error, "Workstation Tailscale is not connected."}

      _ ->
        {:error,
         "Cannot read the local Tailscale daemon. Check that it is running and accessible."}
    end
  end

  defp tailnet_addresses(status) do
    case ipv4_addresses(status["TailscaleIPs"]) do
      [local | _] ->
        peers =
          status
          |> Map.get("Peer", %{})
          |> Map.values()
          |> Enum.filter(&(&1["Online"] == true))
          |> Enum.flat_map(&ipv4_addresses(&1["TailscaleIPs"]))
          |> Enum.uniq()
          |> Enum.sort()

        {:ok, local, peers}

      [] ->
        {:error, "Workstation Tailscale has no IPv4 address."}
    end
  end

  defp ipv4_addresses(addresses) do
    Enum.flat_map(addresses || [], fn address ->
      case parse_address(address) do
        {:ok, ip} -> [ip]
        :error -> []
      end
    end)
  end

  # Current firmware uses the service prefix and its Tailscale IPv4, not a DNS alias.
  def node_address("nerves_gate@" <> address), do: parse_address(address)
  def node_address(_), do: :error

  defp parse_address(address) do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, {_, _, _, _} = ip} -> {:ok, ip}
      _ -> :error
    end
  end

  # The caller owns distribution startup and its cookie. Probe only the named
  # service, then authenticate and identify it with a read-only public API call.
  def discover(addresses) do
    addresses
    |> Enum.uniq()
    |> Task.async_stream(&probe/1,
      max_concurrency: 8,
      timeout: 2 * @probe_timeout + 1_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, gateway}} -> [gateway]
      _ -> []
    end)
    |> Enum.sort_by(& &1.node)
  end

  defp probe(address) do
    case :erl_epmd.port_please(~c"nerves_gate", address, @probe_timeout) do
      {:port, _, _} -> identify(:"nerves_gate@#{:inet.ntoa(address)}")
      _ -> :unavailable
    end
  end

  defp identify(node) do
    case :erpc.call(node, NervesGate, :target, [], @probe_timeout) do
      target when target in [:ec100, :x86_64] -> {:ok, %{node: node, target: target}}
      _ -> :unavailable
    end
  catch
    # Incompatible firmware, authentication failures and unreachable peers are
    # not candidates. Do not expose remote exception data or daemon responses.
    _, _ -> :unavailable
  end

  def select(gateways, target) do
    nodes =
      gateways
      |> Enum.filter(&(&1.target == target))
      |> Enum.map(& &1.node)
      |> Enum.uniq()
      |> Enum.sort()

    case nodes do
      [node] -> {:ok, node}
      [] -> {:error, :not_found}
      nodes -> {:error, {:multiple, nodes}}
    end
  end
end

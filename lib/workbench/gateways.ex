defmodule Workbench.Gateways do
  @moduledoc """
  The Workbench's only device directory.

  A gateway is a `nerves_gate@<ipv4>` node that accepted the development cookie and
  returned a valid `NervesGate.System.info/0`. Simulated and physical gateways are
  the same thing; `source: :qemu` only records that this session's simulator owns
  the virtual hardware. Owned QEMU guests, mDNS, Tailnet peers and manual addresses
  are just candidates to connect to. Disconnected entries keep `last_seen`.
  """
  use GenServer

  @topic "gateways"
  @interval 10_000
  # Tailnet membership is a policy decision; device names are user-editable labels.
  @tailnet_tag "tag:nerves-gate"

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def list, do: GenServer.call(__MODULE__, :list)
  def add(address), do: GenServer.call(__MODULE__, {:add, address})

  def refresh do
    send(__MODULE__, :poll)
    :ok
  end

  def subscribe, do: Phoenix.PubSub.subscribe(NervesGate.PubSub, @topic)

  @doc "Resolve an explicit node, address or owned simulator ID; never select a default."
  def fetch(target) do
    resolve(list(), target)
  catch
    :exit, _ -> {:error, :not_connected}
  end

  def resolve(gateways, target) when is_binary(target) or is_atom(target) do
    matches =
      Enum.filter(gateways, fn gateway ->
        gateway.connected and
          Enum.any?(
            [gateway.node, gateway.address, gateway.sim_id],
            &(not is_nil(&1) and to_string(&1) == to_string(target))
          )
      end)

    case matches do
      [gateway] -> {:ok, gateway}
      [] -> {:error, :not_connected}
      _ -> {:error, :ambiguous_target}
    end
  end

  def resolve(_, _), do: {:error, :explicit_target_required}

  @impl true
  def init(opts) do
    :net_kernel.monitor_nodes(true, node_type: :all)
    if Process.whereis(Simulator), do: Simulator.subscribe()
    if Keyword.get(opts, :poll, true), do: send(self(), :poll)
    {:ok, %{gateways: %{}, manual: [], task: nil}}
  end

  @impl true
  def handle_call(:list, _, state), do: {:reply, sorted(state), state}

  def handle_call({:add, address}, _, state) do
    case host(address) do
      {:ok, host} ->
        send(self(), :poll)
        {:reply, :ok, %{state | manual: Enum.uniq([host | state.manual])}}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info(:poll, %{task: nil} = state) do
    manual = state.manual
    owned = owned()
    known = state.gateways

    task =
      Task.Supervisor.async_nolink(Workbench.Tasks, fn ->
        candidates(owned, discovered() ++ Enum.map(manual, &{&1, :network}))
        |> Task.async_stream(
          fn candidate ->
            case known[candidate.node] do
              %{connected: true} = gateway -> Map.merge(gateway, candidate)
              _ -> verify(candidate)
            end
          end,
          max_concurrency: 8,
          timeout: 8_000,
          on_timeout: :kill_task
        )
        |> Enum.flat_map(fn
          {:ok, entry} -> [entry]
          _ -> []
        end)
      end)

    Process.send_after(self(), :poll, @interval)
    {:noreply, %{state | task: task}}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({:simulator, _}, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  def handle_info({ref, entries}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     publish(%{state | task: nil, gateways: Enum.reduce(entries, state.gateways, &put/2)})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state),
    do: {:noreply, %{state | task: nil}}

  # A node that connected some other way (for example the simulator's boot wait)
  # is verified immediately rather than at the next poll.
  def handle_info({:nodeup, node, _}, state) do
    with "nerves_gate@" <> address <- Atom.to_string(node),
         false <- match?(%{connected: true}, state.gateways[node]),
         %{} = candidate <-
           Enum.find(candidates(owned(), [{address, :network}]), &(&1.node == node)) do
      parent = self()

      Task.Supervisor.start_child(Workbench.Tasks, fn ->
        send(parent, {:verified, verify(candidate)})
      end)
    end

    {:noreply, state}
  end

  def handle_info({:verified, entry}, state),
    do: {:noreply, publish(%{state | gateways: put(entry, state.gateways)})}

  def handle_info({:nodedown, node, _}, state) do
    case state.gateways[node] do
      %{connected: true} = gateway ->
        gateways = Map.put(state.gateways, node, %{gateway | connected: false, error: :node_down})
        {:noreply, publish(%{state | gateways: gateways})}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(_, state), do: {:noreply, state}

  # Owned guests win over a network candidate with the same node.
  @doc false
  def candidates(owned, network) do
    virtual =
      for vm <- owned,
          do: %{node: vm.node, address: vm.address, source: :qemu, sim_id: vm.id}

    physical =
      for {address, _} <- Enum.take(network, 100),
          {:ok, ip} <- [:inet.getaddr(to_charlist(address), :inet)],
          do: %{
            node: String.to_atom("nerves_gate@#{:inet.ntoa(ip)}"),
            address: address,
            source: :network,
            sim_id: nil
          }

    Enum.uniq_by(virtual ++ physical, & &1.node)
  end

  @doc false
  def verify(candidate) do
    Node.set_cookie(candidate.node, :mycookie)

    info =
      Node.connect(candidate.node) &&
        :erpc.call(candidate.node, NervesGate.System, :info, [], 3_000)

    if is_map(info) and info[:node] == candidate.node and
         info[:target] in ["x86_64" | Workbench.Builds.physical_targets()] do
      serial = :erpc.call(candidate.node, Nerves.Runtime, :serial_number, [], 3_000)
      identity = Map.put(info, :serial, serial)
      Map.merge(candidate, %{connected: true, identity: identity, last_seen: now(), error: nil})
    else
      unreachable(candidate, :not_a_gateway)
    end
  catch
    _, _ -> unreachable(candidate, :unreachable)
  end

  defp unreachable(candidate, error) do
    Node.disconnect(candidate.node)
    Map.merge(candidate, %{connected: false, identity: nil, last_seen: nil, error: error})
  end

  # Keep the last identity and sighting of a gateway that is currently unreachable.
  defp put(%{connected: false} = entry, gateways) do
    Map.update(gateways, entry.node, entry, fn old ->
      %{old | connected: false, error: entry.error, source: entry.source, sim_id: entry.sim_id}
    end)
  end

  defp put(entry, gateways) do
    entry =
      case Enum.find(owned(), &(&1.node == entry.node)) do
        nil -> entry
        vm -> %{entry | source: :qemu, sim_id: vm.id}
      end

    entry =
      if entry.node not in Node.list(:connected),
        do: %{entry | connected: false, error: :node_down},
        else: entry

    Map.put(gateways, entry.node, entry)
  end

  defp sorted(state), do: state.gateways |> Map.values() |> Enum.sort_by(&to_string(&1.node))

  defp publish(state) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, @topic, {:gateways, sorted(state)})
    state
  end

  defp owned do
    if Process.whereis(Simulator), do: Map.values(Simulator.devices()), else: []
  catch
    :exit, _ -> []
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp discovered do
    lan =
      for result <- NervesDiscovery.discover(timeout: 2_000, method: :generic),
          result[:product] == "Nerves Gate",
          address <- result[:addresses] || [],
          do: {to_string(:inet.ntoa(address)), :network}

    lan ++ tailnet()
  catch
    _, _ -> []
  end

  defp tailnet do
    case Req.get("http://local-tailscaled.sock/localapi/v0/status",
           unix_socket: "/var/run/tailscale/tailscaled.sock",
           headers: [{"host", "local-tailscaled.sock"}],
           retry: false,
           connect_options: [timeout: 1_000],
           receive_timeout: 2_000
         ) do
      {:ok, %{status: 200, body: status}} -> tailnet_peers(status)
      _ -> []
    end
  end

  @doc false
  def tailnet_peers(%{"Peer" => peers}) when is_map(peers) do
    for peer <- Map.values(peers),
        peer["Online"] == true,
        @tailnet_tag in List.wrap(peer["Tags"]),
        {:ok, host} <- [host(peer["DNSName"])],
        do: {host, :network}
  end

  def tailnet_peers(_), do: []

  @doc "The gateway's own web UI: Tailscale serve over HTTPS, otherwise its LAN listener."
  def url(%{address: address}) do
    if String.ends_with?(address, ".ts.net"),
      do: "https://#{address}/",
      else: "http://#{address}:4000/"
  end

  @doc "A hostname or unicast IPv4 address; never a URL."

  def host(address) when is_binary(address) do
    address = address |> String.trim() |> String.downcase() |> String.trim_trailing(".")

    valid =
      case :inet.parse_ipv4_address(to_charlist(address)) do
        {:ok, {a, _, _, _}} ->
          a in 1..223 and a != 127

        _ ->
          Regex.match?(
            ~r/\A(?=.*[a-z])[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*\z/,
            address
          ) and byte_size(address) <= 253
      end

    if valid, do: {:ok, address}, else: {:error, "Supply a hostname or IPv4 address"}
  end

  def host(_), do: {:error, "Supply a hostname or IPv4 address"}
end

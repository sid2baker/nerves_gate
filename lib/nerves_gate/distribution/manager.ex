defmodule NervesGate.Distribution.Manager do
  @moduledoc "Starts and observes distributed Erlang only after Tailscale has an IPv4 address."

  use GenServer

  alias NervesGate.Alarm
  alias NervesGate.Alarms
  alias NervesGate.Command

  defstruct [:node_name, connected: MapSet.new(), online: false]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []), do: GenServer.start_link(__MODULE__, options, name: __MODULE__)

  @spec ensure_started(String.t()) :: :ok | {:error, term()}
  def ensure_started(ipv4), do: GenServer.call(__MODULE__, {:ensure_started, ipv4}, 8_000)

  @spec status() :: map()
  def status, do: GenServer.call(__MODULE__, :status)

  @impl true
  def init(_options) do
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailscale")
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call({:ensure_started, ipv4}, _from, %{online: true} = state) do
    expected = String.to_atom("nervesgate@#{ipv4}")

    if state.node_name == expected do
      {:reply, :ok, state}
    else
      Alarms.set(Alarm.DistributionFailure)
      {:reply, {:error, :node_name_changed}, state}
    end
  end

  def handle_call({:ensure_started, ipv4}, _from, state) do
    result = start_distribution(ipv4)

    case result do
      {:ok, node_name} ->
        :net_kernel.monitor_nodes(true, node_type: :visible, nodedown_reason: true)
        Alarms.clear(Alarm.DistributionFailure)
        Phoenix.PubSub.broadcast(NervesGate.PubSub, "beam", {:distribution_online, node_name})
        {:reply, :ok, %{state | online: true, node_name: node_name}}

      {:error, reason} ->
        Alarms.set(Alarm.DistributionFailure)
        {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       online: state.online and Node.alive?(),
       node: if(state.node_name, do: Atom.to_string(state.node_name)),
       connected: state.connected |> Enum.map(&Atom.to_string/1) |> Enum.sort()
     }, state}
  end

  @impl true
  def handle_info({:nodeup, node, _info}, state) do
    connected = MapSet.put(state.connected, node)
    publish_nodes(connected)
    {:noreply, %{state | connected: connected}}
  end

  def handle_info({:nodedown, node, _info}, state) do
    connected = MapSet.delete(state.connected, node)
    publish_nodes(connected)
    {:noreply, %{state | connected: connected}}
  end

  def handle_info({:tailscale_changed, _status}, state), do: {:noreply, state}

  defp start_distribution(ipv4) do
    with {:ok, {_a, _b, _c, _d} = address} <-
           :inet.parse_ipv4_address(String.to_charlist(ipv4)),
         :ok <- ensure_epmd(),
         :ok <- configure_distribution(address),
         :ok <- configure_cookie(),
         node_name = String.to_atom("nervesgate@#{ipv4}"),
         {:ok, _pid} <- :net_kernel.start([node_name, :longnames]) do
      {:ok, node_name}
    else
      {:error, {:already_started, _pid}} -> {:ok, Node.self()}
      {:error, :einval} -> {:error, :invalid_tailscale_ipv4}
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_epmd do
    case Command.run("epmd", ["-daemon"], 2_000) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:epmd, reason}}
    end
  end

  defp configure_cookie do
    Node.set_cookie(Application.fetch_env!(:nerves_gate, :distribution_cookie))
    :ok
  end

  defp configure_distribution(address) do
    port = Application.fetch_env!(:nerves_gate, :distribution_port)
    Application.put_env(:kernel, :inet_dist_listen_min, port, persistent: true)
    Application.put_env(:kernel, :inet_dist_listen_max, port, persistent: true)
    Application.put_env(:kernel, :inet_dist_use_interface, address, persistent: true)
    :ok
  end

  defp publish_nodes(connected) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "beam", {:nodes_changed, connected})
  end
end

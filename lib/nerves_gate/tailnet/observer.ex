defmodule NervesGate.Tailnet.Observer do
  @moduledoc "Observes whether this device is attached to its Tailnet and retains peer diagnostics."

  use GenServer

  alias NervesGate.Backoff
  alias NervesGate.Tailnet.Alarms

  @initial_retry 1_000
  @max_retry 30_000
  @max_peers 64

  defstruct [
    :client,
    :repair,
    :timer,
    poll_interval: 5_000,
    retry: @initial_retry,
    failures: 0,
    repair_after: 6,
    status: nil
  ]

  @type normalized :: %{
          online: boolean(),
          authenticated: boolean() | :unknown,
          hostname: String.t() | nil,
          ipv4: String.t() | nil,
          peers: [map()],
          nodes: [map()],
          error: atom() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec status(GenServer.server()) :: normalized()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec poll_now(GenServer.server()) :: :ok
  def poll_now(server \\ __MODULE__), do: GenServer.cast(server, :poll)

  @spec actor_for_ip(String.t(), GenServer.server()) :: map()
  def actor_for_ip(ip, server \\ __MODULE__) do
    status = status(server)
    peer = Enum.find(status.peers, &(&1.ipv4 == ip))

    %{
      ip: ip,
      name: (peer && (peer.user || peer.hostname)) || "tailnet user"
    }
  catch
    :exit, _reason -> %{ip: ip, name: "tailnet user"}
  end

  @impl true
  def init(options) do
    state = %__MODULE__{
      client: Keyword.get(options, :client, NervesGate.Tailscale),
      repair: Keyword.get(options, :repair, &NervesGate.Tailnet.Manager.repair_runtime/0),
      repair_after:
        Keyword.get(
          options,
          :repair_after,
          Application.get_env(:nerves_gate, :tailnet_repair_failures, 6)
        ),
      poll_interval: Keyword.get(options, :poll_interval, 5_000),
      status: offline(:starting)
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_cast(:poll, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    send(self(), :poll)
    {:noreply, %{state | timer: nil}}
  end

  @impl true
  def handle_info(:poll, state) do
    {status, next_delay, retry, failures} = poll(state)
    publish_if_changed(state.status, status)
    Alarms.report(status)

    {:noreply,
     schedule(
       %{state | status: status, retry: retry, failures: failures, timer: nil},
       next_delay
     )}
  end

  @spec normalize(map()) :: normalized()
  def normalize(raw) when is_map(raw) do
    self = Map.get(raw, "Self", %{})
    online = Map.get(self, "Online", false) == true
    backend = Map.get(raw, "BackendState")
    ips = Map.get(self, "TailscaleIPs") || Map.get(raw, "TailscaleIPs") || []
    ipv4 = Enum.find(ips, &ipv4?/1)
    users = Map.get(raw, "User", %{})

    peers =
      raw
      |> Map.get("Peer", %{})
      |> Map.values()
      |> Enum.take(@max_peers)
      |> Enum.map(&normalize_peer(&1, users))
      |> Enum.sort_by(&{&1.hostname || "", &1.ipv4 || ""})

    hostname = Map.get(self, "HostName")

    nodes =
      ([%{hostname: hostname, ipv4: ipv4, online: online, self: true}] ++
         for(
           %{hostname: "nervesgate-" <> _rest} = peer <- peers,
           do: Map.take(peer, [:hostname, :ipv4, :online]) |> Map.put(:self, false)
         ))
      |> Enum.reject(&is_nil(&1.ipv4))

    %{
      online: online and not is_nil(ipv4),
      authenticated: authenticated(backend),
      hostname: hostname,
      ipv4: ipv4,
      peers: peers,
      nodes: nodes,
      error: nil
    }
  end

  def normalize(_raw), do: offline(:invalid_status)

  defp poll(state) do
    case state.client.status() do
      {:ok, raw} ->
        {normalize(raw), state.poll_interval, @initial_retry, 0}

      {:error, _reason} ->
        failures = state.failures + 1
        failures = maybe_repair(state, failures)
        {wait, retry} = Backoff.next(state.retry, @max_retry)
        {offline(:status_unavailable), wait, retry, failures}
    end
  end

  defp maybe_repair(%{repair_after: threshold} = state, failures)
       when failures >= threshold do
    safe_repair(state.repair)
    0
  end

  defp maybe_repair(_state, failures), do: failures

  defp safe_repair(repair) do
    repair.()
  catch
    _kind, _reason -> :ok
  end

  defp normalize_peer(peer, users) do
    ips = Map.get(peer, "TailscaleIPs") || []
    user_id = Map.get(peer, "UserID")
    user = Map.get(users, user_id) || Map.get(users, to_string(user_id)) || %{}

    %{
      online: Map.get(peer, "Online", false) == true,
      hostname: Map.get(peer, "HostName"),
      dns_name: Map.get(peer, "DNSName"),
      ipv4: Enum.find(ips, &ipv4?/1),
      user_id: user_id,
      user: Map.get(user, "DisplayName") || Map.get(user, "LoginName")
    }
  end

  defp ipv4?(ip) when is_binary(ip) do
    match?({:ok, {_a, _b, _c, _d}}, :inet.parse_ipv4_address(String.to_charlist(ip)))
  end

  defp ipv4?(_ip), do: false

  defp authenticated(backend) when backend in ["NeedsLogin", "NoState"], do: false
  defp authenticated(nil), do: :unknown
  defp authenticated(_backend), do: true

  defp offline(reason) do
    %{
      online: false,
      authenticated: :unknown,
      hostname: nil,
      ipv4: nil,
      peers: [],
      nodes: [],
      error: reason
    }
  end

  defp publish_if_changed(previous, current) when previous == current, do: :ok

  defp publish_if_changed(_previous, current) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "tailnet", {:tailnet_changed, current})

    # Compatibility: remove this compatibility topic during the NervesGateWeb refactor.
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "tailscale", {:tailscale_changed, current})
  end

  defp schedule(state, delay) do
    %{state | timer: Process.send_after(self(), :poll, delay)}
  end
end

defmodule NervesGate.Tailscale.Observer do
  @moduledoc "Single owner of Tailscale polling, normalized peer discovery, and change events."

  use GenServer

  alias NervesGate.Alarm
  alias NervesGate.Alarms
  alias NervesGate.Backoff

  @initial_retry 1_000
  @max_retry 30_000
  @max_peers 64

  defstruct [:client, :timer, poll_interval: 5_000, retry: @initial_retry, status: nil]

  @type normalized :: %{
          online: boolean(),
          authenticated: boolean() | :unknown,
          hostname: String.t() | nil,
          ipv4: String.t() | nil,
          peers: [map()],
          nodes: [map()],
          candidates: [node()],
          error: atom() | nil
        }

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec status(GenServer.server()) :: normalized()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec candidates(GenServer.server()) :: [node()]
  def candidates(server \\ __MODULE__), do: GenServer.call(server, :candidates)

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
      poll_interval: Keyword.get(options, :poll_interval, 5_000),
      status: offline(:starting)
    }

    {:ok, schedule(state, 0)}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}
  def handle_call(:candidates, _from, state), do: {:reply, state.status.candidates, state}

  @impl true
  def handle_cast(:poll, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    send(self(), :poll)
    {:noreply, %{state | timer: nil}}
  end

  @impl true
  def handle_info(:poll, state) do
    {status, next_delay, retry} = poll(state)
    publish_if_changed(state.status, status)
    report_alarms(status)
    {:noreply, schedule(%{state | status: status, retry: retry, timer: nil}, next_delay)}
  end

  @spec normalize(map()) :: normalized()
  def normalize(raw) when is_map(raw) do
    self = Map.get(raw, "Self", %{})
    online = Map.get(self, "Online", false) == true
    backend = Map.get(raw, "BackendState")
    ips = Map.get(self, "TailscaleIPs", Map.get(raw, "TailscaleIPs", []))
    ipv4 = Enum.find(ips, &ipv4?/1)
    users = Map.get(raw, "User", %{})

    peers =
      raw
      |> Map.get("Peer", %{})
      |> Map.values()
      |> Enum.take(@max_peers)
      |> Enum.map(&normalize_peer(&1, users))
      |> Enum.sort_by(&{&1.hostname || "", &1.ipv4 || ""})

    candidates =
      for %{online: true, hostname: "nervesgate-" <> _rest, ipv4: ip} <- peers,
          valid_hostname?("nervesgate@#{ip}"),
          do: String.to_atom("nervesgate@#{ip}")

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
      authenticated: backend not in ["NeedsLogin", "NoState"],
      hostname: hostname,
      ipv4: ipv4,
      peers: peers,
      nodes: nodes,
      candidates: Enum.uniq(candidates),
      error: nil
    }
  end

  def normalize(_raw), do: offline(:invalid_status)

  defp poll(state) do
    case state.client.status() do
      {:ok, raw} ->
        {normalize(raw), state.poll_interval, @initial_retry}

      {:error, _reason} ->
        {wait, retry} = Backoff.next(state.retry, @max_retry)
        {offline(:status_unavailable), wait, retry}
    end
  end

  defp normalize_peer(peer, users) do
    ips = Map.get(peer, "TailscaleIPs", [])
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

  defp valid_hostname?(name),
    do: byte_size(name) <= 255 and String.match?(name, ~r/^nervesgate@[0-9.]+$/)

  defp offline(reason) do
    %{
      online: false,
      authenticated: :unknown,
      hostname: nil,
      ipv4: nil,
      peers: [],
      nodes: [],
      candidates: [],
      error: reason
    }
  end

  defp report_alarms(status) do
    Alarms.toggle(Alarm.TailscaleOffline, not status.online)
    report_authentication_alarm(status.authenticated)
  end

  defp report_authentication_alarm(true), do: Alarms.clear(Alarm.TailscaleAuthenticationRequired)
  defp report_authentication_alarm(false), do: Alarms.set(Alarm.TailscaleAuthenticationRequired)
  defp report_authentication_alarm(:unknown), do: :ok

  defp publish_if_changed(previous, current) when previous == current, do: :ok

  defp publish_if_changed(_previous, current) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "tailscale", {:tailscale_changed, current})
  end

  defp schedule(state, delay) do
    %{state | timer: Process.send_after(self(), :poll, delay)}
  end
end

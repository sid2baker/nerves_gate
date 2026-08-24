defmodule NervesGate.Tailnet.Observer do
  @moduledoc "Projects typed tailscale_ex state into NervesGate's public Tailnet view."

  use GenServer

  alias NervesGate.Tailnet.Address
  alias NervesGate.Tailnet.Alarms

  @type normalized :: %{
          online: boolean(),
          authenticated: boolean() | :unknown,
          hostname: String.t() | nil,
          ipv4: String.t() | nil,
          peers: [map()],
          nodes: [map()],
          subnet_router: map(),
          health: Tailscale.Health.t(),
          error: atom() | nil
        }

  defstruct [:source, :health, :read_status, :route_status, :route_retry, status: nil]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec status(GenServer.server()) :: normalized()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__), do: GenServer.cast(server, :refresh)

  @spec actor_for_ip(String.t(), GenServer.server()) :: map()
  def actor_for_ip(ip, server \\ __MODULE__) do
    peer = Enum.find(status(server).peers, &(&1.ipv4 == ip))
    %{ip: ip, name: (peer && peer.hostname) || "tailnet user"}
  catch
    :exit, _reason -> %{ip: ip, name: "tailnet user"}
  end

  @impl true
  def init(options) do
    enabled =
      Keyword.get(
        options,
        :enabled,
        Application.get_env(:nerves_gate, :tailscale_enabled, true)
      )

    source = Tailscale.Status.unknown()
    health = Tailscale.Health.initial()
    status = offline(if(enabled, do: :starting, else: :disabled), health)

    state = %__MODULE__{
      source: source,
      health: health,
      read_status: Keyword.get(options, :read_status, &Tailscale.status/0),
      route_status: Keyword.get(options, :route_status, &Tailscale.route_status/0),
      status: status
    }

    Alarms.report(status)

    if enabled and Keyword.get(options, :subscribe, true) do
      :ok = Keyword.get(options, :subscriber, &Tailscale.subscribe/0).()
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  @impl true
  def handle_cast(:refresh, state) do
    source =
      case state.read_status.() do
        {:ok, %Tailscale.Status{} = source} -> source
        {:error, _reason} -> state.source
      end

    {:noreply, observe(state, source)}
  end

  @impl true
  def handle_info({:tailscale, :status_changed, _generation, %Tailscale.Status{} = source}, state) do
    {:noreply, observe(state, source)}
  end

  def handle_info(
        {:tailscale, :health_changed, _generation, %Tailscale.Health{} = health},
        state
      ) do
    status = project(state.source, state.status.subnet_router, health)
    publish(state, status)
    {:noreply, %{state | health: health, status: status}}
  end

  def handle_info(:refresh_routes, state) do
    {:noreply, state |> Map.put(:route_retry, nil) |> observe(state.source)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @doc false
  @spec project(Tailscale.Status.t(), map(), Tailscale.Health.t()) :: normalized()
  def project(
        %Tailscale.Status{} = source,
        routes \\ unavailable_routes(),
        health \\ Tailscale.Health.initial()
      ) do
    ipv4 = valid_ipv4(source.ipv4)
    online = source.online == true and not is_nil(ipv4)

    peers =
      Enum.map(source.peers, fn peer ->
        %{
          online: peer.online == true,
          hostname: peer.hostname,
          dns_name: peer.dns_name,
          ipv4: valid_ipv4(peer.ipv4),
          user_id: peer.id,
          user: nil
        }
      end)

    nodes =
      ([%{hostname: source.hostname, ipv4: ipv4, online: online, self: true}] ++
         for(
           %{hostname: "nervesgate-" <> _rest} = peer <- peers,
           do: Map.take(peer, [:hostname, :ipv4, :online]) |> Map.put(:self, false)
         ))
      |> Enum.reject(&is_nil(&1.ipv4))

    %{
      online: online,
      authenticated: source.authenticated,
      hostname: source.hostname,
      ipv4: ipv4,
      peers: peers,
      nodes: nodes,
      subnet_router: routes,
      health: health,
      error: if(online, do: nil, else: status_error(source))
    }
  end

  defp observe(state, source) do
    routes =
      if source.online == true, do: route_status(state.route_status), else: unavailable_routes()

    status = project(source, routes, state.health)
    publish(state, status)

    state
    |> Map.merge(%{source: source, status: status})
    |> schedule_route_retry(source, routes)
  end

  defp route_status(read) do
    case read.() do
      {:ok, routes} -> Map.put(routes, :error, nil)
      {:error, _reason} -> unavailable_routes()
    end
  end

  defp schedule_route_retry(state, %{online: true}, %{error: :unavailable}) do
    if state.route_retry,
      do: state,
      else: %{state | route_retry: Process.send_after(self(), :refresh_routes, 5_000)}
  end

  defp schedule_route_retry(state, _source, _routes) do
    if state.route_retry, do: Process.cancel_timer(state.route_retry)
    %{state | route_retry: nil}
  end

  defp valid_ipv4(address) when is_binary(address) do
    if match?({:ok, _parsed}, Address.parse_ipv4(address)), do: address
  end

  defp valid_ipv4(_address), do: nil

  defp status_error(%{backend_state: :needs_login}), do: :needs_login
  defp status_error(%{backend_state: :needs_machine_auth}), do: :needs_machine_auth
  defp status_error(%{backend_state: :stopped}), do: :stopped
  defp status_error(%{online: true}), do: :address_unavailable
  defp status_error(_source), do: :status_unavailable

  defp offline(reason, health) do
    %{
      online: false,
      authenticated: :unknown,
      hostname: nil,
      ipv4: nil,
      peers: [],
      nodes: [],
      subnet_router: unavailable_routes(),
      health: health,
      error: reason
    }
  end

  defp unavailable_routes,
    do: %{advertised: [], approved: [], primary: [], error: :unavailable}

  defp publish(state, status) do
    if state.status != status do
      Phoenix.PubSub.local_broadcast(
        NervesGate.PubSub,
        "tailnet",
        {:tailnet_changed, status}
      )
    end

    Alarms.report(status)
  end
end

defmodule NervesGate.Setup do
  @moduledoc """
  The complete initialization flow: Internet → Tailscale → cluster → ready.

  Each public function performs one step and advances the persisted phase only
  after that step succeeds. The small API is shared by LiveView, HTTP, and tests.
  """

  use GenServer

  alias NervesGate.Alarm
  alias NervesGate.Alarms
  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Commissioning.Access
  alias NervesGate.Distribution.Manager, as: DistributionManager
  alias NervesGate.Network.Config
  alias NervesGate.Network.Manager, as: NetworkManager
  alias NervesGate.Store
  alias NervesGate.Tailscale
  alias NervesGate.Tailscale.Observer

  @phases [:internet, :tailscale, :cluster, :ready, :recovery]

  defstruct [:root, :phase, :error, :ops]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec configure_internet(map(), GenServer.server()) ::
          {:ok, :tailscale | :ready} | {:error, term()}
  def configure_internet(params, server \\ __MODULE__) do
    with {:ok, config} <- Config.new(internet_params(params)) do
      GenServer.call(server, {:configure_internet, config}, 35_000)
    end
  end

  @spec configure_tailscale(String.t(), GenServer.server()) :: {:ok, :cluster} | {:error, term()}
  def configure_tailscale(auth_token, server \\ __MODULE__)

  def configure_tailscale(auth_token, server)
      when is_binary(auth_token) and byte_size(auth_token) in 8..512 do
    GenServer.call(server, {:configure_tailscale, auth_token}, 20_000)
  end

  def configure_tailscale(_auth_token, _server), do: {:error, :invalid_auth_token}

  @spec configure_cluster(GenServer.server()) :: {:ok, :ready} | {:error, term()}
  def configure_cluster(server \\ __MODULE__),
    do: GenServer.call(server, :configure_cluster, 10_000)

  @spec recover(atom(), GenServer.server()) :: :ok
  def recover(reason \\ :requested, server \\ __MODULE__) do
    GenServer.cast(server, {:recover, reason})
  end

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(options) do
    root = Keyword.get(options, :root, Store.root())
    ops = Keyword.get(options, :ops, default_ops())
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailscale")

    {phase, error} = load_phase(root)
    state = %__MODULE__{root: root, phase: phase, error: error, ops: ops}
    send(self(), :resume)
    {:ok, state}
  end

  @impl true
  def handle_call({:configure_internet, config}, _from, state) do
    case state.ops.network.(config) do
      {:ok, _checks} ->
        next_phase = if state.phase in [:internet, :recovery], do: :tailscale, else: state.phase
        state = set_phase(state, next_phase)
        state.ops.start_tailscale.()
        {:reply, {:ok, next_phase}, %{state | error: nil}}

      {:error, reason} ->
        next_state =
          if state.phase in [:internet, :recovery] do
            state.ops.access.(:commissioning, known_uplink(state.root))
            %{state | phase: :internet}
          else
            state
          end

        {:reply, {:error, reason}, %{next_state | error: public_error(reason)}}
    end
  end

  def handle_call({:configure_tailscale, _token}, _from, %{phase: :internet} = state) do
    {:reply, {:error, :internet_required}, state}
  end

  def handle_call({:configure_tailscale, token}, _from, state) do
    case enroll(state.ops.tailscale, token) do
      :ok ->
        state.ops.poll_tailscale.()
        {:reply, {:ok, :cluster}, state |> set_phase(:cluster) |> Map.put(:error, nil)}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: public_error(reason)}}
    end
  end

  def handle_call(:configure_cluster, _from, %{phase: :ready} = state) do
    {:reply, {:ok, :ready}, state}
  end

  def handle_call(:configure_cluster, _from, state) do
    case start_cluster(state) do
      {:ok, state} -> {:reply, {:ok, :ready}, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:status, _from, state) do
    {:reply,
     %{
       phase: state.phase,
       ready: state.phase == :ready,
       recovery: state.phase == :recovery,
       error: state.error,
       access: safe_access_status()
     }, state}
  end

  @impl true
  def handle_cast({:recover, reason}, state) do
    state.ops.access.(:recovery, known_uplink(state.root))
    Alarms.set(Alarm.CommissioningRequired)
    {:noreply, %{set_phase(state, :recovery) | error: reason}}
  end

  @impl true
  def handle_info(:resume, state) do
    {:noreply, resume(state)}
  end

  def handle_info({:tailscale_changed, %{online: true} = tailscale}, %{phase: phase} = state)
      when phase in [:cluster, :ready] do
    case start_cluster(state, tailscale) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:noreply, %{state | error: public_error(reason)}}
    end
  end

  def handle_info({:tailscale_changed, _status}, state), do: {:noreply, state}

  defp resume(%{phase: :internet} = state) do
    Alarms.set(Alarm.CommissioningRequired)
    state.ops.access.(:commissioning, nil)
    state
  end

  defp resume(%{phase: :tailscale} = state) do
    Alarms.set(Alarm.CommissioningRequired)
    state.ops.access.(:commissioning, known_uplink(state.root))
    state.ops.start_tailscale.()
    state
  end

  defp resume(%{phase: phase} = state) when phase in [:cluster, :ready] do
    if phase == :cluster do
      Alarms.set(Alarm.CommissioningRequired)
      state.ops.access.(:commissioning, known_uplink(state.root))
    end

    state.ops.start_tailscale.()
    state.ops.poll_tailscale.()
    state
  end

  defp resume(%{phase: :recovery} = state) do
    Alarms.set(Alarm.CommissioningRequired)
    state.ops.access.(:recovery, known_uplink(state.root))
    state
  end

  defp start_cluster(state, tailscale \\ nil) do
    tailscale = tailscale || state.ops.tail_status.()

    with %{online: true, ipv4: ipv4} when is_binary(ipv4) <- tailscale,
         :ok <- state.ops.distribution.(ipv4),
         :ok <- state.ops.cluster.(),
         :ok <- state.ops.disable_access.() do
      Alarms.clear(Alarm.CommissioningRequired)
      {:ok, state |> set_phase(:ready) |> Map.put(:error, nil)}
    else
      %{online: false} -> {:error, :tailscale_offline, state}
      {:error, reason} -> {:error, reason, state}
      _other -> {:error, :tailscale_not_ready, state}
    end
  end

  defp set_phase(state, phase) when phase in @phases do
    case Store.write_phase(phase, state.root) do
      :ok ->
        Phoenix.PubSub.broadcast(NervesGate.PubSub, "setup", {:setup_changed, phase})
        %{state | phase: phase}

      {:error, reason} ->
        Alarms.set(Alarm.StorageFailure)
        state.ops.access.(:recovery, known_uplink(state.root))
        %{state | phase: :recovery, error: public_error(reason)}
    end
  end

  defp load_phase(root) do
    result =
      with :ok <- Store.initialize(root),
           {:ok, %{"phase" => phase}} <- Store.read_setup(root) do
        {:ok, String.to_existing_atom(phase)}
      end

    case result do
      {:ok, phase} ->
        Store.write_phase(phase, root)
        {phase, nil}

      {:error, reason} ->
        Alarms.set(Alarm.StorageFailure)
        Store.write_phase(:recovery, root)
        {:recovery, public_error(reason)}
    end
  end

  defp internet_params(params) when is_map(params) do
    params = stringify_keys(params)
    ip_address = Map.get(params, "ip_address")
    method = Map.get(params, "method")
    method = method || if(ip_address in [nil, "", "dhcp"], do: "dhcp", else: "static")

    params
    |> Map.put_new("interface", "eth0")
    |> Map.put_new("kind", "ethernet")
    |> Map.put("method", method)
    |> maybe_put_address(ip_address)
    |> copy_key("dns", "dns_primary")
  end

  defp internet_params(_params), do: %{}

  defp stringify_keys(params) do
    Map.new(params, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      pair -> pair
    end)
  end

  defp maybe_put_address(params, ip) when ip in [nil, "", "dhcp"], do: params
  defp maybe_put_address(params, ip), do: Map.put_new(params, "address", ip)

  defp copy_key(params, source, destination) do
    case Map.get(params, source) do
      nil -> params
      value -> Map.put_new(params, destination, value)
    end
  end

  defp known_uplink(root) do
    case Store.read_network(root) do
      {:ok, %Config{interface: interface}} -> interface
      _other -> nil
    end
  end

  defp safe_access_status do
    Access.status()
  catch
    :exit, _reason -> %{active: [], mode: :unavailable}
  end

  defp enroll(enroll, token) do
    enroll.(token)
  catch
    _kind, _reason -> {:error, :authentication_failed}
  end

  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(_reason), do: :operation_failed

  defp default_ops do
    %{
      network: &NetworkManager.apply_candidate/1,
      tailscale: &Tailscale.enroll/1,
      start_tailscale: &Tailscale.ensure_started/0,
      poll_tailscale: &Observer.poll_now/0,
      tail_status: &Observer.status/0,
      distribution: &DistributionManager.ensure_started/1,
      cluster: &ClusterManager.ensure_started/0,
      access: &Access.enable/2,
      disable_access: &Access.disable/0
    }
  end
end

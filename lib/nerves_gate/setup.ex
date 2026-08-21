defmodule NervesGate.Setup do
  @moduledoc """
  Persists the three commissioning choices: Internet, Tailnet, and Cluster.

  Runtime health is owned by the three domain managers and is never persisted
  here. The phase file remains temporarily for the current web UI and can be
  removed during the NervesGateWeb refactor.
  """

  use GenServer

  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Commissioning.Access
  alias NervesGate.Commissioning.Alarms, as: CommissioningAlarms
  alias NervesGate.Internet.Config
  alias NervesGate.Internet.Manager, as: InternetManager
  alias NervesGate.Storage.Alarms, as: StorageAlarms
  alias NervesGate.Store
  alias NervesGate.Tailnet.Observer
  alias NervesGate.Tailscale

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
    GenServer.call(server, {:configure_tailscale, fn -> auth_token end}, 20_000)
  end

  def configure_tailscale(_auth_token, _server), do: {:error, :invalid_auth_token}

  @doc "Compatibility call for the current web controller; selects singular mode."
  @spec configure_cluster() :: {:ok, :ready} | {:error, term()}
  def configure_cluster, do: configure_cluster(nil, __MODULE__)

  @doc "Configures a cookie, or accepts the old explicit server argument for singular mode."
  @spec configure_cluster(String.t() | nil | GenServer.server()) ::
          {:ok, :ready} | {:error, term()}
  def configure_cluster(cookie) when is_binary(cookie) or is_nil(cookie),
    do: configure_cluster(cookie, __MODULE__)

  def configure_cluster(server), do: configure_cluster(nil, server)

  @spec configure_cluster(String.t() | nil, GenServer.server()) ::
          {:ok, :ready} | {:error, term()}
  def configure_cluster(cookie, server) do
    with {:ok, cookie} <- ClusterManager.validate_cookie(cookie) do
      GenServer.call(server, {:configure_cluster, fn -> cookie end}, 10_000)
    end
  end

  @spec configure_cluster_cookie(String.t() | nil, GenServer.server()) ::
          {:ok, :ready} | {:error, term()}
  def configure_cluster_cookie(cookie, server \\ __MODULE__),
    do: configure_cluster(cookie, server)

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
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailnet")

    {phase, error} = load_phase(root)
    state = %__MODULE__{root: root, phase: phase, error: error, ops: ops}
    send(self(), :resume)
    {:ok, state}
  end

  @impl true
  def handle_call({:configure_internet, config}, _from, state) do
    case state.ops.internet.(config) do
      {:ok, _checks} ->
        next_phase = if state.phase in [:internet, :recovery], do: :tailscale, else: state.phase
        state = set_phase(state, next_phase)
        state.ops.start_tailnet.()
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

  def handle_call({:configure_tailscale, _load_token}, _from, %{phase: :internet} = state) do
    {:reply, {:error, :internet_required}, state}
  end

  def handle_call({:configure_tailscale, load_token}, _from, state) do
    case enroll(state.ops.enroll_tailnet, load_token.()) do
      :ok ->
        state.ops.poll_tailnet.()
        {:reply, {:ok, :cluster}, state |> set_phase(:cluster) |> Map.put(:error, nil)}

      {:error, reason} ->
        {:reply, {:error, reason}, %{state | error: public_error(reason)}}
    end
  end

  def handle_call({:configure_cluster, _load_cookie}, _from, %{phase: :internet} = state) do
    {:reply, {:error, :internet_required}, state}
  end

  def handle_call({:configure_cluster, _load_cookie}, _from, %{phase: :tailscale} = state) do
    {:reply, {:error, :tailnet_required}, state}
  end

  def handle_call({:configure_cluster, load_cookie}, _from, state) do
    case safe_configure_cluster(state.ops.configure_cluster, load_cookie.()) do
      :ok ->
        CommissioningAlarms.required(false)
        Process.send_after(self(), :disable_setup_access, 1_000)
        {:reply, {:ok, :ready}, state |> set_phase(:ready) |> Map.put(:error, nil)}

      {:error, reason} ->
        {:reply, {:error, public_error(reason)}, %{state | error: public_error(reason)}}
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
    CommissioningAlarms.required(true)
    {:noreply, %{set_phase(state, :recovery) | error: reason}}
  end

  @impl true
  def handle_info(:resume, state), do: {:noreply, resume(state)}

  def handle_info({:tailnet_changed, %{online: true}}, %{phase: :tailscale} = state) do
    {:noreply, set_phase(state, :cluster)}
  end

  def handle_info({:tailnet_changed, _status}, state), do: {:noreply, state}

  def handle_info(:disable_setup_access, state) do
    state.ops.disable_access.()
    {:noreply, state}
  end

  defp resume(%{phase: :internet} = state) do
    case Store.read_network(state.root) do
      {:ok, %Config{}} -> state |> set_phase(:tailscale) |> resume()
      _missing_or_invalid -> enable_setup_access(state, :commissioning, nil)
    end
  end

  defp resume(%{phase: :tailscale} = state) do
    state
    |> enable_setup_access(:commissioning, known_uplink(state.root))
    |> poll_tailnet()
  end

  defp resume(%{phase: :cluster} = state) do
    state
    |> enable_setup_access(:commissioning, known_uplink(state.root))
    |> poll_tailnet()
  end

  defp resume(%{phase: :ready} = state) do
    CommissioningAlarms.required(false)
    state.ops.disable_access.()
    poll_tailnet(state)
  end

  defp resume(%{phase: :recovery} = state) do
    enable_setup_access(state, :recovery, known_uplink(state.root))
  end

  defp enable_setup_access(state, mode, uplink) do
    CommissioningAlarms.required(true)
    state.ops.access.(mode, uplink)
    state
  end

  defp poll_tailnet(state) do
    state.ops.poll_tailnet.()
    state
  end

  defp set_phase(state, phase) when phase in @phases do
    case Store.write_phase(phase, state.root) do
      :ok ->
        Phoenix.PubSub.broadcast(NervesGate.PubSub, "setup", {:setup_changed, phase})
        %{state | phase: phase}

      {:error, reason} ->
        StorageAlarms.failure(true)
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
        StorageAlarms.failure(true)
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

  defp safe_configure_cluster(configure, cookie) do
    configure.(cookie)
  catch
    _kind, _reason -> {:error, :cluster_configuration_failed}
  end

  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(_reason), do: :operation_failed

  defp default_ops do
    %{
      internet: &InternetManager.apply_candidate/1,
      enroll_tailnet: &Tailscale.enroll/1,
      start_tailnet: &Tailscale.ensure_started/0,
      poll_tailnet: &Observer.poll_now/0,
      configure_cluster: &ClusterManager.configure/1,
      access: &Access.enable/2,
      disable_access: &Access.disable/0
    }
  end
end

defmodule NervesGate.Cluster.Manager do
  @moduledoc "Owns optional distributed Erlang on the Tailnet. It performs no peer discovery."

  use GenServer

  alias NervesGate.Cluster.Alarms
  alias NervesGate.Cluster.Distribution
  alias NervesGate.Storage.Alarms, as: StorageAlarms
  alias NervesGate.Store
  alias NervesGate.Tailnet.Observer

  @cookie_pattern ~r/\A[A-Za-z0-9_-]+\z/

  defstruct [
    :cookie,
    :node_name,
    :runtime_ip,
    :timer,
    :root,
    :ops,
    connected: MapSet.new(),
    online: false,
    interval: 5_000,
    last_error: nil
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec configure(String.t() | nil, GenServer.server()) :: :ok | {:error, term()}
  def configure(cookie, server \\ __MODULE__) do
    with {:ok, cookie} <- validate_cookie(cookie) do
      GenServer.call(server, {:configure, fn -> cookie end}, 10_000)
    end
  end

  @spec reconcile(GenServer.server()) :: :ok
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile, 10_000)

  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @spec validate_cookie(term()) :: {:ok, String.t() | nil} | {:error, :invalid_cluster_cookie}
  def validate_cookie(value) when value in [nil, ""], do: {:ok, nil}

  def validate_cookie(value) when is_binary(value) and byte_size(value) in 8..128 do
    if String.match?(value, @cookie_pattern),
      do: {:ok, value},
      else: {:error, :invalid_cluster_cookie}
  end

  def validate_cookie(_value), do: {:error, :invalid_cluster_cookie}

  @impl true
  def init(options) do
    root = Keyword.get(options, :root, Store.root())
    {cookie, storage_error?} = load_cookie(root)

    state = %__MODULE__{
      root: root,
      cookie: cookie,
      ops: Keyword.get(options, :ops, default_ops()),
      interval:
        Keyword.get(
          options,
          :interval,
          Application.get_env(:nerves_gate, :cluster_poll_interval, 5_000)
        )
    }

    if storage_error?, do: StorageAlarms.failure(true)
    Alarms.report(not is_nil(cookie), false)
    Phoenix.PubSub.subscribe(NervesGate.PubSub, "tailnet")
    send(self(), :reconcile)
    {:ok, state}
  end

  @impl true
  def handle_call({:configure, load_cookie}, _from, state) do
    cookie = load_cookie.()

    case Store.write_cluster(cookie, state.root) do
      :ok ->
        state = apply_cookie(state, cookie)
        {:reply, :ok, state}

      {:error, _reason} ->
        StorageAlarms.failure(true)
        {:reply, {:error, :cluster_persistence_failed}, state}
    end
  end

  def handle_call(:reconcile, _from, state) do
    {:reply, :ok, reconcile_runtime(state)}
  end

  def handle_call(:status, _from, state), do: {:reply, public_status(state), state}

  @impl true
  def handle_info(:reconcile, state) do
    state = %{state | timer: nil} |> reconcile_runtime() |> schedule()
    {:noreply, state}
  end

  def handle_info({:tailnet_changed, _status}, state) do
    {:noreply, reconcile_runtime(state)}
  end

  def handle_info({:nodeup, node, _info}, state) do
    state = %{state | connected: MapSet.put(state.connected, node)}
    publish(state)
    {:noreply, state}
  end

  def handle_info({:nodedown, node, _info}, state) do
    state = %{state | connected: MapSet.delete(state.connected, node)}
    publish(state)
    {:noreply, state}
  end

  defp apply_cookie(%{cookie: cookie} = state, cookie), do: reconcile_runtime(state)

  defp apply_cookie(state, cookie) do
    state
    |> stop_runtime()
    |> Map.put(:cookie, cookie)
    |> reconcile_runtime()
  end

  defp reconcile_runtime(%{cookie: nil} = state) do
    state = stop_runtime(state)
    Alarms.report(false, false)
    publish(state)
    state
  end

  defp reconcile_runtime(state) do
    case safe_tailnet_status(state.ops.tail_status) do
      %{online: true, ipv4: ipv4} when is_binary(ipv4) -> reconcile_enabled(state, ipv4)
      _blocked -> blocked(state)
    end
  end

  defp reconcile_enabled(state, ipv4) do
    if state.online and state.runtime_ip == ipv4 and state.ops.alive?.() do
      state = %{state | connected: MapSet.new(state.ops.connected.()), last_error: nil}
      Alarms.report(true, false)
      publish(state)
      state
    else
      state
      |> stop_runtime()
      |> start_runtime(ipv4)
    end
  end

  defp start_runtime(state, ipv4) do
    # This is the only string-to-atom conversion for the credential. The value
    # has been strictly validated and explicitly loaded from local configuration.
    cookie = String.to_atom(state.cookie)

    case safe_start(state.ops.start, ipv4, cookie) do
      {:ok, node_name} when is_atom(node_name) ->
        state = %{
          state
          | online: true,
            runtime_ip: ipv4,
            node_name: node_name,
            connected: MapSet.new(state.ops.connected.()),
            last_error: nil
        }

        Alarms.report(true, false)
        publish(state)
        state

      {:error, reason} ->
        state = %{state | last_error: public_error(reason)}
        Alarms.report(true, true)
        publish(state)
        state
    end
  end

  defp blocked(state) do
    state = stop_runtime(state)
    Alarms.report(true, false)
    publish(state)
    state
  end

  defp stop_runtime(state) do
    if (state.online or state.node_name) || state.ops.alive?.() do
      state.ops.stop.()
    end

    %{
      state
      | online: false,
        runtime_ip: nil,
        node_name: nil,
        connected: MapSet.new(),
        last_error: nil
    }
  end

  defp public_status(state) do
    online = state.online and state.ops.alive?.()

    %{
      enabled: not is_nil(state.cookie),
      online: online,
      node: if(online, do: state.node_name),
      connected: if(online, do: state.connected |> MapSet.to_list() |> Enum.sort(), else: [])
    }
  end

  defp publish(state) do
    status = public_status(state)
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "cluster", {:cluster_changed, status})
  end

  defp load_cookie(root) do
    case Store.read_cluster(root) do
      {:ok, cookie} -> {cookie, false}
      {:error, _reason} -> {nil, true}
    end
  end

  defp safe_tailnet_status(status) do
    status.()
  catch
    _kind, _reason -> %{online: false, ipv4: nil}
  end

  defp safe_start(start, ipv4, cookie) do
    start.(ipv4, cookie)
  catch
    _kind, _reason -> {:error, :distribution_start_failed}
  end

  defp schedule(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :reconcile, state.interval)}
  end

  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error(_reason), do: :distribution_start_failed

  defp default_ops do
    %{
      tail_status: &Observer.status/0,
      start: &Distribution.start/2,
      stop: &Distribution.stop/0,
      alive?: &Distribution.alive?/0,
      connected: &Distribution.connected/0
    }
  end
end

defimpl Inspect, for: NervesGate.Cluster.Manager do
  import Inspect.Algebra

  def inspect(state, opts) do
    safe = %{
      enabled: not is_nil(state.cookie),
      online: state.online,
      node: state.node_name,
      connected: MapSet.size(state.connected),
      last_error: state.last_error
    }

    concat(["#NervesGate.Cluster.Manager<", to_doc(safe, opts), ">"])
  end
end

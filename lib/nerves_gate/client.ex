defmodule NervesGate.Client do
  @moduledoc """
  Process-free reducer for one caller's complete local and fleet state.

  The caller owns this immutable value and passes incoming DeviceState and
  Fleet operations through `reduce/2`, just as a Livebook client applies an
  ordered stream. Subscriptions are tied directly to the caller process;
  no disposable session process or dynamic supervisor is needed.
  """

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.Client, as: StateClient
  alias NervesGate.Fleet

  @enforce_keys [
    :subscriber,
    :device_state_server,
    :fleet_server,
    :local,
    :fleet_boot_id,
    :fleet_revision,
    :replicas
  ]
  defstruct @enforce_keys

  @type fleet :: %{local: DeviceState.snapshot(), replicas: %{String.t() => Fleet.replica()}}

  @type t :: %__MODULE__{
          subscriber: pid(),
          device_state_server: GenServer.server(),
          fleet_server: GenServer.server(),
          local: StateClient.t(),
          fleet_boot_id: String.t(),
          fleet_revision: non_neg_integer(),
          replicas: %{String.t() => Fleet.replica()}
        }

  @type reduction :: {:ok, t(), :changed | :duplicate | :ignored} | :resync

  @spec connect(keyword()) :: {:ok, t()} | {:error, term()}
  def connect(options \\ []) do
    subscriber = Keyword.get(options, :subscriber, self())
    device_state_server = Keyword.get(options, :device_state, NervesGate.DeviceState.Server)
    fleet_server = Keyword.get(options, :fleet, Fleet)

    try do
      case subscribe(subscriber, device_state_server, fleet_server) do
        {:ok, _client} = success ->
          success

        {:error, _reason} = error ->
          unsubscribe(subscriber, device_state_server, fleet_server)
          error
      end
    catch
      :exit, reason ->
        unsubscribe(subscriber, device_state_server, fleet_server)
        {:error, public_error(reason)}
    end
  end

  @spec disconnect(t()) :: :ok
  def disconnect(%__MODULE__{} = client) do
    :ok = DeviceState.unsubscribe(client.subscriber, client.device_state_server)
    :ok = Fleet.unsubscribe(client.subscriber, client.fleet_server)
  catch
    :exit, _reason -> :ok
  end

  @spec resync(t()) :: {:ok, t()} | {:error, term()}
  def resync(%__MODULE__{} = client) do
    with {:ok, local_snapshot} <-
           DeviceState.subscribe(client.subscriber, client.device_state_server),
         {:ok, local} <- install_local(local_snapshot),
         {:ok, fleet_snapshot} <- Fleet.subscribe(client.subscriber, client.fleet_server) do
      {:ok,
       %{
         client
         | local: local,
           fleet_boot_id: fleet_snapshot.boot_id,
           fleet_revision: fleet_snapshot.revision,
           replicas: fleet_snapshot.replicas
       }}
    else
      :error -> {:error, :invalid_state_snapshot}
    end
  catch
    :exit, reason -> {:error, public_error(reason)}
  end

  @spec reduce(t(), term()) :: reduction()
  def reduce(%__MODULE__{} = client, {:device_state_operation, _, _, _, _} = operation) do
    case StateClient.reduce(client.local, operation) do
      {:ok, local, result} -> {:ok, %{client | local: local}, result}
      :resync -> :resync
    end
  end

  def reduce(
        %__MODULE__{fleet_boot_id: boot_id, fleet_revision: previous} = client,
        {:fleet_operation, boot_id, revision, operation}
      )
      when revision == previous + 1 do
    case reduce_fleet(client.replicas, operation) do
      {:ok, replicas} ->
        {:ok, %{client | replicas: replicas, fleet_revision: revision}, :changed}

      :error ->
        :resync
    end
  end

  def reduce(
        %__MODULE__{fleet_boot_id: boot_id, fleet_revision: current} = client,
        {:fleet_operation, boot_id, revision, _operation}
      )
      when revision <= current,
      do: {:ok, client, :duplicate}

  def reduce(%__MODULE__{}, {:fleet_operation, _boot_id, _revision, _operation}), do: :resync
  def reduce(%__MODULE__{} = client, _message), do: {:ok, client, :ignored}

  @spec state(t()) :: fleet()
  def state(%__MODULE__{} = client) do
    %{local: StateClient.snapshot(client.local), replicas: client.replicas}
  end

  @spec configured?(t()) :: boolean()
  def configured?(%__MODULE__{} = client) do
    case client.local.state.configuration do
      %{configured: configured} -> configured
      _unhydrated -> false
    end
  end

  @spec actor_for_ip(t(), String.t()) :: map()
  def actor_for_ip(%__MODULE__{} = client, remote_ip) do
    peer =
      case client.local.state.tailnet do
        %{peers: peers} -> Enum.find(peers, &(&1.ipv4 == remote_ip))
        _unhydrated -> nil
      end

    %{ip: remote_ip, name: (peer && peer.hostname) || "tailnet user"}
  end

  @spec discovery(t()) :: map()
  def discovery(%__MODULE__{} = client) do
    state = client.local.state
    device = state.device || %{}
    tailnet = state.tailnet
    cluster = state.cluster

    %{
      gateway_id: Map.get(device, :device_id),
      hostname: (tailnet && tailnet.hostname) || Map.get(device, :name),
      cluster_group: cluster && cluster.group
    }
  end

  @spec status(t() | fleet()) :: map()
  def status(%__MODULE__{} = client), do: client |> state() |> status()

  def status(%{local: _local, replicas: _replicas} = fleet) do
    %{
      schema: "nerves_gate.status.v3",
      local: public_snapshot(fleet.local),
      replicas:
        Map.new(fleet.replicas, fn {id, replica} ->
          {id,
           public_term(%{
             boot_id: replica.boot_id,
             revision: replica.revision,
             connected: replica.connected,
             last_seen_at: replica.last_seen_at,
             state: replica.state
           })}
        end)
    }
  end

  defp subscribe(subscriber, device_state_server, fleet_server) do
    with {:ok, local_snapshot} <- DeviceState.subscribe(subscriber, device_state_server),
         {:ok, local} <- install_local(local_snapshot),
         {:ok, fleet_snapshot} <- Fleet.subscribe(subscriber, fleet_server) do
      {:ok,
       %__MODULE__{
         subscriber: subscriber,
         device_state_server: device_state_server,
         fleet_server: fleet_server,
         local: local,
         fleet_boot_id: fleet_snapshot.boot_id,
         fleet_revision: fleet_snapshot.revision,
         replicas: fleet_snapshot.replicas
       }}
    else
      :error -> {:error, :invalid_state_snapshot}
    end
  end

  defp unsubscribe(subscriber, device_state_server, fleet_server) do
    DeviceState.unsubscribe(subscriber, device_state_server)
    Fleet.unsubscribe(subscriber, fleet_server)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp install_local(snapshot), do: StateClient.install(Map.put_new(snapshot, :node, node()))

  defp reduce_fleet(replicas, {:put, id, replica}) when is_binary(id) and is_map(replica),
    do: {:ok, Map.put(replicas, id, replica)}

  defp reduce_fleet(replicas, {:delete, id}) when is_binary(id),
    do: {:ok, Map.delete(replicas, id)}

  defp reduce_fleet(_replicas, _operation), do: :error

  defp public_snapshot(snapshot) do
    public_term(%{
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      hydrated: snapshot.hydrated,
      state: snapshot.state
    })
  end

  defp public_term(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp public_term(%_{} = struct), do: struct |> Map.from_struct() |> public_term()

  defp public_term(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, public_term(item)} end)
  end

  defp public_term(value) when is_list(value), do: Enum.map(value, &public_term/1)
  defp public_term({a, b, c, d}), do: {a, b, c, d} |> :inet.ntoa() |> List.to_string()
  defp public_term(value), do: value

  defp public_error({:noproc, _details}), do: :state_unavailable
  defp public_error({:shutdown, _details}), do: :state_unavailable
  defp public_error(_reason), do: :state_unavailable
end

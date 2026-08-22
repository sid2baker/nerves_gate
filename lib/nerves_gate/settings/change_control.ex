defmodule NervesGate.Settings.ChangeControl do
  @moduledoc "Persists the active settings-change lock and inhibits expected dependency alarms."

  use GenServer

  alias NervesGate.Settings.Maintenance
  alias NervesGate.Storage.Alarms, as: StorageAlarms
  alias NervesGate.Store

  defstruct [:active, :monitor, :root, :last_result]

  @type kind :: :internet | :tailnet | :cluster

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @spec begin_change(kind(), String.t(), pid(), String.t(), map(), GenServer.server()) ::
          :ok | {:error, term()}
  def begin_change(kind, id, owner, source_connection, rollback, server \\ __MODULE__)
      when kind in [:internet, :tailnet, :cluster] and is_binary(id) and is_pid(owner) and
             is_binary(source_connection) and is_map(rollback) do
    GenServer.call(server, {:begin, kind, id, owner, source_connection, rollback})
  end

  @spec awaiting_confirmation(String.t(), map(), non_neg_integer(), GenServer.server()) ::
          :ok | {:error, term()}
  def awaiting_confirmation(id, rollback, timeout, server \\ __MODULE__)
      when is_binary(id) and is_map(rollback) and is_integer(timeout) and timeout > 0 do
    GenServer.call(server, {:awaiting_confirmation, id, rollback, timeout})
  end

  @spec rolling_back(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def rolling_back(id, server \\ __MODULE__) do
    GenServer.call(server, {:phase, id, :rolling_back})
  end

  @spec finish(String.t(), term(), GenServer.server()) :: :ok | {:error, term()}
  def finish(id, result \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:finish, id, result})
  end

  @spec active(kind() | nil, GenServer.server()) :: map() | nil
  def active(kind \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:active, kind})
  end

  @spec status(String.t() | nil, GenServer.server()) :: map()
  def status(connection_id \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:status, connection_id})
  end

  @impl true
  def init(options) do
    root = Keyword.get(options, :root, Store.root())

    case Store.read_settings_change(root) do
      {:ok, nil} ->
        Maintenance.clear()
        {:ok, %__MODULE__{root: root}}

      {:ok, journal} ->
        active = active_from_journal(journal)
        Maintenance.begin(active.kind)
        {:ok, %__MODULE__{root: root, active: active}}

      {:error, reason} ->
        StorageAlarms.failure(true)
        {:stop, {:settings_journal_unavailable, reason}}
    end
  end

  @impl true
  def handle_call(
        {:begin, _kind, _id, _owner, _connection, _rollback},
        _from,
        %{active: active} = state
      )
      when not is_nil(active) do
    {:reply, {:error, :settings_change_in_progress}, state}
  end

  def handle_call({:begin, kind, id, owner, source_connection, rollback}, _from, state) do
    active = %{
      id: id,
      kind: kind,
      phase: :applying,
      rollback: rollback,
      source_connection: source_connection,
      started_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      confirmation_deadline: nil,
      last_error: nil
    }

    case persist(state.root, active) do
      :ok ->
        monitor = Process.monitor(owner)
        Maintenance.begin(kind)
        state = %{state | active: active, monitor: monitor, last_result: nil}
        publish(state)
        {:reply, :ok, state}

      {:error, reason} ->
        StorageAlarms.failure(true)
        {:reply, {:error, {:settings_journal_failed, reason}}, state}
    end
  end

  def handle_call(
        {:awaiting_confirmation, id, rollback, timeout},
        _from,
        %{active: %{id: id}} = state
      ) do
    active = %{
      state.active
      | phase: :awaiting_confirmation,
        rollback: rollback,
        confirmation_deadline: System.monotonic_time(:millisecond) + timeout
    }

    update_active(state, active)
  end

  def handle_call({:awaiting_confirmation, _id, _rollback, _timeout}, _from, state) do
    {:reply, {:error, :settings_change_not_found}, state}
  end

  def handle_call({:phase, id, phase}, _from, %{active: %{id: id}} = state) do
    update_active(state, %{state.active | phase: phase})
  end

  def handle_call({:phase, _id, _phase}, _from, state) do
    {:reply, {:error, :settings_change_not_found}, state}
  end

  def handle_call({:finish, id, result}, _from, %{active: %{id: id}} = state) do
    case Store.clear_settings_change(state.root) do
      :ok ->
        if state.monitor, do: Process.demonitor(state.monitor, [:flush])
        Maintenance.clear()
        state = %{state | active: nil, monitor: nil, last_result: result}
        publish_finished(result)
        {:reply, :ok, state}

      {:error, reason} ->
        StorageAlarms.failure(true)
        {:reply, {:error, {:settings_journal_failed, reason}}, state}
    end
  end

  def handle_call({:finish, _id, _result}, _from, state) do
    {:reply, {:error, :settings_change_not_found}, state}
  end

  def handle_call({:active, nil}, _from, state), do: {:reply, state.active, state}

  def handle_call({:active, kind}, _from, %{active: %{kind: kind}} = state),
    do: {:reply, state.active, state}

  def handle_call({:active, _kind}, _from, state), do: {:reply, nil, state}

  def handle_call({:status, connection_id}, _from, state) do
    {:reply, public_status(state, connection_id), state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _owner, reason}, %{monitor: monitor} = state) do
    active = %{
      state.active
      | phase: :rolling_back,
        source_connection: nil,
        confirmation_deadline: nil,
        last_error: {:owner_stopped, reason}
    }

    case persist(state.root, active) do
      :ok ->
        state = %{state | active: active, monitor: nil}
        publish(state)
        {:noreply, state}

      {:error, journal_reason} ->
        StorageAlarms.failure(true)
        {:stop, {:settings_journal_failed, journal_reason}, state}
    end
  end

  defp update_active(state, active) do
    case persist(state.root, active) do
      :ok ->
        state = %{state | active: active}
        publish(state)
        {:reply, :ok, state}

      {:error, reason} ->
        StorageAlarms.failure(true)
        {:reply, {:error, {:settings_journal_failed, reason}}, state}
    end
  end

  defp persist(root, active) do
    Store.write_settings_change(
      %{
        "version" => 1,
        "id" => active.id,
        "kind" => Atom.to_string(active.kind),
        "phase" => Atom.to_string(active.phase),
        "rollback" => active.rollback,
        "started_at" => active.started_at
      },
      root
    )
  end

  defp active_from_journal(journal) do
    %{
      id: journal["id"],
      kind: String.to_existing_atom(journal["kind"]),
      phase: :rolling_back,
      rollback: journal["rollback"],
      source_connection: nil,
      started_at: journal["started_at"],
      confirmation_deadline: nil,
      last_error: :recovered_unconfirmed_change
    }
  end

  defp public_status(state, connection_id) do
    %{
      pending: if(state.active, do: public_active(state.active, connection_id)),
      maintenance: Maintenance.layers(),
      last_error: (state.active && state.active.last_error) || state.last_result
    }
  end

  defp public_active(active, connection_id) do
    %{
      id: active.id,
      kind: active.kind,
      phase: active.phase,
      started_at: active.started_at,
      remaining_seconds: remaining_seconds(active.confirmation_deadline),
      confirmable:
        active.phase == :awaiting_confirmation and
          active.source_connection != connection_id
    }
  end

  defp remaining_seconds(nil), do: nil

  defp remaining_seconds(deadline) do
    max(0, div(deadline - System.monotonic_time(:millisecond) + 999, 1_000))
  end

  defp publish(state) do
    Phoenix.PubSub.local_broadcast(
      NervesGate.PubSub,
      "settings",
      {:settings_changed, public_status(state, nil)}
    )
  end

  defp publish_finished(result) do
    Phoenix.PubSub.local_broadcast(
      NervesGate.PubSub,
      "settings",
      {:settings_changed, %{pending: nil, maintenance: [], last_error: result}}
    )
  end
end

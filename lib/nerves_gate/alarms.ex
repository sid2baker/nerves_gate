defmodule NervesGate.Alarms do
  @moduledoc """
  Generic Alarmist runtime for subsystem-owned alarm graphs.

  Each subsystem owns its signals, managed conditions, public alarms, and remedy
  declarations. This module only installs them, publishes explicitly
  public transitions, and supplies secret-safe logging helpers.
  """

  require Logger

  @subsystems [
    NervesGate.DeviceState.Alarms,
    NervesGate.Commissioning.Alarms,
    NervesGate.Storage.Alarms,
    NervesGate.Internet.Alarms,
    NervesGate.Tailnet.Alarms,
    NervesGate.Cluster.Alarms,
    NervesGate.SSH.Alarms,
    NervesGate.SubnetRouter.Alarms
  ]

  @type remedy_declaration ::
          {Alarmist.alarm_id(), Alarmist.remedy_fn(), Alarmist.remedy_options()}

  @spec set(Alarmist.alarm_id(), String.t()) :: :ok
  def set(id, description) when is_binary(description) do
    :alarm_handler.set_alarm({id, description})
  end

  @spec clear(Alarmist.alarm_id()) :: :ok
  def clear(id), do: :alarm_handler.clear_alarm(id)

  @doc "Synchronizes a truthful boolean signal into Alarmist."
  @spec report(Alarmist.alarm_id(), boolean(), String.t()) :: :ok
  def report(id, true, description), do: set(id, description)
  def report(id, false, _description), do: clear(id)

  @doc false
  @spec report_sync(Alarmist.alarm_id(), boolean(), String.t()) :: :ok
  def report_sync(id, active, description) do
    expected = if active, do: :set, else: :clear
    :ok = report(id, active, description)

    # A newer ordered projection may supersede this signal while Alarmist is
    # still processing it. That is convergence, not an invariant failure.
    case await_state(id, expected) do
      :ok -> :ok
      {:error, :alarm_state_timeout} -> :ok
    end
  end

  @doc false
  @spec await_state(Alarmist.alarm_id(), :set | :clear, non_neg_integer()) ::
          :ok | {:error, :alarm_state_timeout}
  def await_state(id, expected, attempts \\ 100)

  def await_state(id, expected, attempts) do
    if Alarmist.alarm_state(id) == expected do
      :ok
    else
      await_state_retry(id, expected, attempts)
    end
  end

  @doc "Installs subsystem-owned signal levels, managed alarms, and runtime remedies."
  @spec install(keyword()) :: :ok
  def install(options \\ []) do
    validate_declarations!()

    Enum.each(@subsystems, fn subsystem ->
      Enum.each(subsystem.alarm_levels(), fn {id, level} ->
        :ok = Alarmist.set_alarm_level(id, level)
      end)
    end)

    Enum.each(@subsystems, fn subsystem ->
      Enum.each(subsystem.managed_alarms(), fn id ->
        :ok = Alarmist.add_managed_alarm(id)
      end)
    end)

    sync_remedies(Keyword.get(options, :healing_enabled, true))
  end

  @doc false
  @spec remedy_declarations() :: [remedy_declaration()]
  def remedy_declarations do
    Enum.flat_map(@subsystems, & &1.remedies())
  end

  @doc "Subscribes the calling process to explicitly public alarm transitions."
  @spec subscribe_public() :: :ok
  def subscribe_public do
    Enum.each(public_ids(), fn id -> :ok = Alarmist.subscribe(id) end)
    :ok
  end

  @spec public_ids() :: [Alarmist.alarm_id()]
  def public_ids do
    @subsystems
    |> Enum.flat_map(& &1.public_alarms())
    |> Enum.uniq()
  end

  @doc "Returns the currently set public alarms in stable identifier order."
  @spec active() :: [map()]
  def active do
    public_ids()
    |> Enum.filter(&(Alarmist.alarm_state(&1) == :set))
    |> Enum.map(&public_alarm/1)
    |> Enum.sort_by(& &1.id)
  end

  @spec public_event(Alarmist.Event.t()) :: {:set, map()} | {:clear, String.t()} | :ignore
  def public_event(%Alarmist.Event{id: id, state: state}) do
    if id in public_ids(), do: public_transition(state, id), else: :ignore
  end

  @doc "Logs a public transition without using caller descriptions or alarm parameters."
  @spec log_transition(Alarmist.Event.t()) :: :ok
  def log_transition(%Alarmist.Event{state: :clear, previous_state: :unknown}), do: :ok

  def log_transition(%Alarmist.Event{id: id, state: state}) when state in [:set, :clear] do
    if id in public_ids(), do: log_public(state, public_alarm(id)), else: :ok
  end

  def log_transition(%Alarmist.Event{}), do: :ok

  @doc "Whether genuine operational transition history should currently be recorded."
  @spec operational_monitoring?() :: boolean()
  def operational_monitoring? do
    Alarmist.alarm_state(NervesGate.DeviceState.Signal.Changing) != :set and
      Alarmist.alarm_state(NervesGate.Commissioning.Signal.Required) == :clear and
      Alarmist.alarm_state(NervesGate.Storage.Signal.Failure) != :set
  end

  @doc "Runs and records one bounded Alarmist remedy without logging private error terms."
  @spec heal(module(), (-> term())) :: term()
  def heal(alarm, function) when is_atom(alarm) and is_function(function, 0) do
    started = System.monotonic_time(:millisecond)
    result = function.()
    duration = System.monotonic_time(:millisecond) - started
    public_id = alarm.public_id()
    outcome = heal_outcome(result)

    Logger.info("alarm heal: #{public_id} #{outcome}",
      heal: true,
      alarm_id: public_id,
      heal_result: outcome,
      heal_duration_ms: duration
    )

    result
  end

  defp validate_declarations! do
    Enum.each(@subsystems, &validate_subsystem!/1)

    public_ids = Enum.map(public_ids(), & &1.public_id())
    remedy_ids = Enum.map(remedy_declarations(), &elem(&1, 0))

    if length(public_ids) != length(Enum.uniq(public_ids)) do
      raise ArgumentError, "public alarm identifiers must be unique"
    end

    if length(remedy_ids) != length(Enum.uniq(remedy_ids)) do
      raise ArgumentError, "managed alarms may declare only one remedy"
    end

    :ok
  end

  defp validate_subsystem!(subsystem) do
    managed = subsystem.managed_alarms()

    if Enum.any?(subsystem.public_alarms(), &(&1 not in managed)) do
      raise ArgumentError, "every public alarm must be managed by its owning subsystem"
    end

    if Enum.any?(subsystem.remedies(), fn {alarm, _callback, _options} ->
         alarm not in managed
       end) do
      raise ArgumentError, "every remedy must belong to a managed alarm in its subsystem"
    end
  end

  defp sync_remedies(true) do
    Enum.each(remedy_declarations(), fn {alarm, callback, options} ->
      :ok = Alarmist.add_remedy(alarm, callback, options)
    end)

    :ok
  end

  defp sync_remedies(false) do
    Enum.each(remedy_declarations(), fn {alarm, _callback, _options} ->
      case Alarmist.remove_remedy(alarm) do
        :ok -> :ok
        {:error, :not_found} -> :ok
      end
    end)

    :ok
  end

  defp await_state_retry(_id, _expected, 0), do: {:error, :alarm_state_timeout}

  defp await_state_retry(id, expected, attempts) do
    Process.sleep(1)
    await_state(id, expected, attempts - 1)
  end

  defp public_transition(:set, id), do: {:set, public_alarm(id)}
  defp public_transition(:clear, id), do: {:clear, id.public_id()}
  defp public_transition(:unknown, _id), do: :ignore

  defp public_alarm(id) do
    %{id: id.public_id(), description: id.description(), level: id.__alarm_level__()}
  end

  defp log_public(state, alarm) do
    log_level = if state == :set, do: alarm.level, else: :info

    Logger.log(log_level, "alarm #{state}: #{alarm.id}",
      alarm: true,
      alarm_id: alarm.id,
      alarm_state: state,
      alarm_level: alarm.level,
      alarm_description: alarm.description
    )

    :ok
  end

  @doc false
  @spec sync_public_state(NervesGate.DeviceState.State.t(), atom(), term()) :: :ok
  def sync_public_state(state, source, previous \\ nil)

  def sync_public_state(state, :configuration, _previous) do
    configuration = state.configuration || %{}
    NervesGate.DeviceState.Alarms.changing(not is_nil(Map.get(configuration, :pending)))
    NervesGate.Commissioning.Alarms.required(not Map.get(configuration, :configured, false))
  end

  def sync_public_state(state, :commissioning, _previous) do
    commissioning = state.commissioning || %{}
    NervesGate.Commissioning.Alarms.unavailable(Map.get(commissioning, :state) == :waiting)
  end

  def sync_public_state(state, :internet, previous) when is_map(state.internet),
    do: NervesGate.Internet.Alarms.report(state.internet, previous)

  def sync_public_state(state, :tailnet, _previous) when is_map(state.tailnet),
    do: NervesGate.Tailnet.Alarms.report(state.tailnet)

  def sync_public_state(state, :ssh, _previous) when is_map(state.ssh),
    do: NervesGate.SSH.Alarms.report(state.ssh)

  def sync_public_state(state, :cluster, _previous) when is_map(state.cluster) do
    enabled = Map.get(state.cluster, :enabled, false)

    NervesGate.Cluster.Alarms.report(
      enabled,
      enabled and not Map.get(state.cluster, :online, false)
    )
  end

  def sync_public_state(state, :subnet_router, _previous) when is_map(state.subnet_router) do
    enabled = Map.get(state.subnet_router, :enabled, false)

    NervesGate.SubnetRouter.Alarms.failure(
      enabled and Map.get(state.subnet_router, :state) != :active
    )
  end

  def sync_public_state(_state, _source, _previous), do: :ok

  defp heal_outcome(:ok), do: :ok
  defp heal_outcome({:ok, _value}), do: :ok
  defp heal_outcome({:error, reason}) when is_atom(reason), do: reason
  defp heal_outcome({:error, _reason}), do: :failed
  defp heal_outcome(_result), do: :invalid_result
end

defmodule NervesGate.Alarms.Runtime do
  @moduledoc """
  Projects canonical public state into subsystem-owned Alarmist policy.

  Alarm evidence comes only from the atomic DeviceState snapshot/event stream.
  The runtime ignores its own `:alarms` state events for signal derivation and
  publishes the complete active alarm state after Alarmist transitions.
  """

  use GenServer

  alias NervesGate.Alarms
  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.State

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    healing_enabled =
      Keyword.get(
        options,
        :healing_enabled,
        Application.get_env(:nerves_gate, :alarm_healing_enabled, true)
      )

    server = Keyword.get(options, :device_state, NervesGate.DeviceState.Server)
    :ok = Alarms.subscribe_public()
    :ok = Alarms.install(healing_enabled: healing_enabled)
    {:ok, snapshot} = DeviceState.subscribe(self(), server)

    state = %{
      device_state: snapshot.state,
      boot_id: snapshot.boot_id,
      revision: snapshot.revision,
      device_state_server: server,
      healing_enabled: healing_enabled
    }

    sync_snapshot(snapshot.state)
    :ok = publish_active()
    {:ok, state}
  end

  @impl true
  def handle_info(%Alarmist.Event{} = event, state) do
    Alarms.log_transition(event)
    :ok = publish_active()
    {:noreply, state}
  end

  def handle_info(
        {:device_state_event, _node, boot_id, revision,
         {:state_reported, source, _value} = event},
        %{boot_id: boot_id, revision: previous} = state
      )
      when revision == previous + 1 do
    previous_slice = Map.fetch!(state.device_state, source)

    case State.apply_event(state.device_state, event) do
      {:ok, device_state} ->
        if source != :alarms,
          do: Alarms.sync_public_state(device_state, source, previous_slice)

        {:noreply, %{state | device_state: device_state, revision: revision}}

      :error ->
        {:stop, :invalid_device_state_event, state}
    end
  end

  def handle_info(
        {:device_state_event, _node, boot_id, revision, _event},
        %{boot_id: boot_id, revision: current} = state
      )
      when revision <= current,
      do: {:noreply, state}

  def handle_info({:device_state_event, _node, _boot, _revision, _event}, state) do
    {:ok, snapshot} = DeviceState.subscribe(self(), state.device_state_server)
    sync_snapshot(snapshot.state)

    {:noreply,
     %{
       state
       | device_state: snapshot.state,
         boot_id: snapshot.boot_id,
         revision: snapshot.revision
     }}
  end

  defp sync_snapshot(%State{} = state) do
    Enum.each(State.sources() -- [:device, :alarms], fn source ->
      Alarms.sync_public_state(state, source)
    end)
  end

  defp publish_active do
    case DeviceState.publish({:state_reported, :alarms, Alarms.active()}) do
      :ok -> :ok
      {:error, :shutting_down} -> :ok
      {:error, reason} -> raise "Alarm DeviceState publication failed: #{inspect(reason)}"
    end
  end
end

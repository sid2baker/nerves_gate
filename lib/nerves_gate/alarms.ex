defmodule NervesGate.Alarms do
  @moduledoc "Generic, secret-safe Alarmist infrastructure. Domain logic lives with each subsystem."

  @spec set(Alarmist.alarm_id(), String.t()) :: :ok
  def set(id, description) when is_binary(description) do
    :alarm_handler.set_alarm({id, description})
  end

  @spec clear(Alarmist.alarm_id()) :: :ok
  def clear(id), do: :alarm_handler.clear_alarm(id)

  @spec toggle(Alarmist.alarm_id(), boolean(), String.t()) :: :ok
  def toggle(id, true, description), do: set(id, description)
  def toggle(id, false, _description), do: clear(id)

  @spec active() :: [map()]
  def active do
    Alarmist.get_alarms(level: :info)
    |> Enum.map(fn {id, _description} -> public_alarm(id, alarm_level(id)) end)
    |> Enum.sort_by(& &1.id)
  catch
    :exit, _reason -> []
  end

  @spec public_event(Alarmist.Event.t()) :: {:set, map()} | {:clear, String.t()} | :ignore
  def public_event(%Alarmist.Event{level: level} = event) do
    if Logger.compare_levels(level, :info) == :lt do
      :ignore
    else
      case event.state do
        :set -> {:set, public_alarm(event.id, level)}
        :clear -> {:clear, encode_id(event.id)}
        :unknown -> :ignore
      end
    end
  end

  @spec encode_id(Alarmist.alarm_id()) :: String.t()
  def encode_id(id) when is_atom(id), do: inspect(id)

  def encode_id(id) when is_tuple(id) do
    id
    |> Tuple.to_list()
    |> Enum.map_join(":", fn value ->
      if is_atom(value), do: inspect(value), else: to_string(value)
    end)
  end

  defp public_alarm(id, level) do
    %{id: encode_id(id), description: safe_description(id), level: level}
  end

  defp alarm_level(id) do
    type = Alarmist.alarm_type(id)
    configured = Application.get_env(:alarmist, :alarm_levels, %{})

    Map.get(configured, id) || Map.get(configured, type) || module_level(type)
  end

  defp module_level(type) do
    if Code.ensure_loaded?(type) and function_exported?(type, :__alarm_level__, 0),
      do: type.__alarm_level__(),
      else: :warning
  end

  defp safe_description(id) do
    type = Alarmist.alarm_type(id)

    if Code.ensure_loaded?(type) and function_exported?(type, :description, 0),
      do: type.description(),
      else: "Operational condition requires attention"
  end
end

defmodule NervesGate.Alarms.Reporter do
  @moduledoc "Logs Alarmist transitions and preserves the existing PubSub notification."
  use GenServer

  require Logger

  def start_link(options \\ []) do
    name = Keyword.get(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @impl true
  def init(_options) do
    :ok = Alarmist.subscribe_all()
    {:ok, %{}}
  end

  @impl true
  def handle_info(%Alarmist.Event{} = event, state) do
    log_transition(event)
    NervesGate.DeviceState.Server.alarm_transition(event)
    Phoenix.PubSub.broadcast(NervesGate.PubSub, "alarms", {:alarms_changed, event.state})
    {:noreply, state}
  end

  @doc false
  @spec log_transition(Alarmist.Event.t()) :: :ok
  def log_transition(%Alarmist.Event{} = event) do
    alarm_id = inspect(event.id)

    Logger.log(event.level, "alarm #{event.state}: #{alarm_id}",
      alarm: true,
      alarm_id: alarm_id,
      alarm_state: event.state,
      alarm_level: event.level,
      alarm_description: safe_description(event.id)
    )
  end

  defp safe_description(id) do
    type = Alarmist.alarm_type(id)

    if Code.ensure_loaded?(type) and function_exported?(type, :description, 0),
      do: type.description(),
      else: "Operational condition changed"
  end
end

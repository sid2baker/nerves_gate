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
    |> Enum.map(fn {id, description} ->
      %{id: encode_id(id), description: description}
    end)
    |> Enum.sort_by(& &1.id)
  catch
    :exit, _reason -> []
  end

  defp encode_id(id) when is_atom(id), do: inspect(id)

  defp encode_id(id) when is_tuple(id) do
    id
    |> Tuple.to_list()
    |> Enum.map_join(":", fn value ->
      if is_atom(value), do: inspect(value), else: to_string(value)
    end)
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

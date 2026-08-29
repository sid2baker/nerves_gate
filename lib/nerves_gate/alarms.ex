defmodule NervesGate.Alarms do
  @moduledoc """
  Derives the complete public alarm list from canonical DeviceState.

  Alarm dependency policy lives in one owner instead of a graph of signal,
  condition, alarm, and remedy modules. Resource owners already reconcile their
  own failures, so alarms are observation rather than a second healing system.
  The only private evidence not represented by public owner state is sticky
  persistent-storage failure.
  """

  use GenServer

  require Logger

  alias NervesGate.DeviceState
  alias NervesGate.DeviceState.Client

  @catalog %{
    "cluster_unavailable" => %{description: "Cluster unavailable", level: :warning},
    "commissioning_required" => %{
      description: "Device commissioning is required",
      level: :warning
    },
    "commissioning_unavailable" => %{
      description: "No local commissioning interface is available",
      level: :error
    },
    "internet_unavailable" => %{description: "Internet unavailable", level: :warning},
    "internet_unstable" => %{
      description: "Internet connectivity is unstable",
      level: :warning
    },
    "ssh_unavailable" => %{description: "Tailnet-only SSH unavailable", level: :warning},
    "storage_failure" => %{
      description: "Persistent storage is unavailable or corrupt",
      level: :error
    },
    "subnet_router_unavailable" => %{
      description: "Subnet router configuration could not be applied",
      level: :warning
    },
    "tailnet_unavailable" => %{description: "Tailnet unavailable", level: :warning}
  }

  @debounced_ids ~w(internet_unavailable tailnet_unavailable cluster_unavailable ssh_unavailable subnet_router_unavailable)

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @doc "Records or clears sticky persistent-storage failure evidence."
  @spec storage_failure(boolean(), GenServer.server()) :: :ok
  def storage_failure(active, server \\ __MODULE__)

  def storage_failure(active, __MODULE__) when is_boolean(active) do
    :persistent_term.put({__MODULE__, :storage_failure}, active)
    notify_storage_failure(__MODULE__, active)
  end

  def storage_failure(active, server) when is_boolean(active),
    do: notify_storage_failure(server, active)

  @doc "Returns the stable public alarm identifiers."
  @spec public_ids() :: [String.t()]
  def public_ids, do: @catalog |> Map.keys() |> Enum.sort()

  @doc "Returns the currently active canonical public alarms."
  @spec active(GenServer.server()) :: [map()]
  def active(server \\ __MODULE__) do
    GenServer.call(server, :active)
  catch
    :exit, _reason -> []
  end

  @spec diagnostics(GenServer.server()) :: map() | nil
  def diagnostics(server \\ __MODULE__) do
    GenServer.call(server, :diagnostics)
  catch
    :exit, _reason -> nil
  end

  @impl true
  def init(options) do
    timings =
      Keyword.get(options, :timings, Application.fetch_env!(:nerves_gate, :alarm_timings))

    server = Keyword.get(options, :device_state, NervesGate.DeviceState.Server)
    {:ok, snapshot} = DeviceState.subscribe(self(), server)
    {:ok, client} = Client.install(snapshot)

    state = %{
      client: client,
      device_state_server: server,
      storage_failure: initial_storage_failure(options),
      candidates: %{},
      internet_samples: [],
      unstable_until: nil,
      alarms: [],
      published_alarms: client.state.alarms || [],
      clock: Keyword.get(options, :clock, fn -> System.monotonic_time(:millisecond) end),
      debounce: timings.failure_debounce,
      flapping_count: timings.flapping_count,
      flapping_period: timings.flapping_period,
      flapping_hold: timings.flapping_hold,
      tick_interval: min(1_000, max(10, div(max(timings.failure_debounce, 1), 2)))
    }

    schedule_tick(state)
    {:ok, publish(recompute(state))}
  end

  @impl true
  def handle_call({:storage_failure, active}, _from, state) do
    state = state |> Map.put(:storage_failure, active) |> recompute() |> publish()
    {:reply, :ok, state}
  end

  def handle_call(:active, _from, state), do: {:reply, state.alarms, state}

  def handle_call(:diagnostics, _from, state) do
    {:reply,
     %{
       state: :observing,
       desired: %{},
       observed: %{alarms: state.alarms},
       blocked_by: nil,
       last_error: nil,
       attempt: 0,
       retry_at: nil
     }, state}
  end

  @impl true
  def handle_info(
        {:device_state_operation, _node, _boot, _revision, {:put, source, _value}} = operation,
        state
      ) do
    previous_internet = internet_online(state.client.state)

    case Client.reduce(state.client, operation) do
      {:ok, client, :changed} ->
        state = %{state | client: client}

        state =
          if source == :internet, do: track_internet_change(state, previous_internet), else: state

        {:noreply, state |> recompute() |> publish()}

      {:ok, _client, :duplicate} ->
        {:noreply, state}

      :resync ->
        {:noreply, resync(state)}
    end
  end

  def handle_info({:device_state_heartbeat, _, _, _}, state), do: {:noreply, state}

  def handle_info(:tick, state) do
    schedule_tick(state)
    {:noreply, state |> recompute() |> publish()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp resync(state) do
    {:ok, snapshot} = DeviceState.subscribe(self(), state.device_state_server)
    {:ok, client} = Client.install(snapshot)

    state
    |> Map.merge(%{client: client, published_alarms: client.state.alarms || []})
    |> recompute()
    |> publish()
  end

  defp recompute(state) do
    now = now(state)
    conditions = debounced_conditions(state)

    candidates =
      Enum.reduce(@debounced_ids, state.candidates, fn id, candidates ->
        if Map.get(conditions, id, false) do
          Map.put_new(candidates, id, now)
        else
          Map.delete(candidates, id)
        end
      end)

    debounced =
      for id <- @debounced_ids,
          started_at = Map.get(candidates, id),
          is_integer(started_at),
          now - started_at >= state.debounce,
          do: id

    immediate = immediate_alarms(state)

    unstable =
      if operational?(state) and is_integer(state.unstable_until) and now < state.unstable_until,
        do: ["internet_unstable"],
        else: []

    alarms =
      (immediate ++ debounced ++ unstable)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&public_alarm/1)

    %{state | candidates: candidates, alarms: alarms}
  end

  defp immediate_alarms(%{storage_failure: true}), do: ["storage_failure"]

  defp immediate_alarms(state) do
    public = state.client.state
    configured = configured?(public)
    waiting = match?(%{state: :waiting}, public.commissioning)

    cond do
      configured -> []
      waiting -> ["commissioning_unavailable"]
      true -> ["commissioning_required"]
    end
  end

  defp debounced_conditions(state) do
    %{
      "internet_unavailable" => internet_unavailable?(state),
      "tailnet_unavailable" => tailnet_unavailable?(state),
      "cluster_unavailable" => cluster_unavailable?(state),
      "ssh_unavailable" => ssh_unavailable?(state),
      "subnet_router_unavailable" => subnet_router_unavailable?(state)
    }
  end

  defp internet_unavailable?(state) do
    operational?(state) and not match?(%{online: true}, state.client.state.internet)
  end

  defp tailnet_unavailable?(state) do
    upstream_healthy?(state) and not match?(%{online: true}, state.client.state.tailnet)
  end

  defp cluster_unavailable?(state) do
    tailnet_healthy?(state) and
      match?(%{enabled: true, online: false}, state.client.state.cluster)
  end

  defp ssh_unavailable?(state) do
    ssh = state.client.state.ssh

    tailnet_healthy?(state) and match?(%{enabled: true}, ssh) and
      not match?(%{state: :listening}, ssh)
  end

  defp subnet_router_unavailable?(state) do
    subnet_router = state.client.state.subnet_router

    tailnet_healthy?(state) and match?(%{enabled: true}, subnet_router) and
      not match?(%{state: :active}, subnet_router)
  end

  defp upstream_healthy?(state) do
    operational?(state) and match?(%{online: true}, state.client.state.internet)
  end

  defp tailnet_healthy?(state) do
    upstream_healthy?(state) and match?(%{online: true}, state.client.state.tailnet)
  end

  defp track_internet_change(state, previous) do
    current = internet_online(state.client.state)

    if is_boolean(previous) and is_boolean(current) and previous != current and
         operational?(state) do
      now = now(state)

      samples =
        [now | state.internet_samples]
        |> Enum.filter(&(now - &1 <= state.flapping_period))

      unstable_until =
        if length(samples) >= state.flapping_count,
          do: now + state.flapping_hold,
          else: state.unstable_until

      %{state | internet_samples: samples, unstable_until: unstable_until}
    else
      state
    end
  end

  defp operational?(state) do
    not state.storage_failure and configured?(state.client.state) and
      not changing?(state.client.state)
  end

  defp configured?(%{configuration: %{configured: true}}), do: true
  defp configured?(_state), do: false

  defp changing?(%{configuration: %{pending: pending}}), do: not is_nil(pending)
  defp changing?(_state), do: false

  defp internet_online(%{internet: %{online: online}}) when is_boolean(online), do: online
  defp internet_online(_state), do: nil

  defp publish(%{alarms: alarms, published_alarms: previous} = state) do
    if previous == alarms do
      state
    else
      log_changes(previous, alarms)

      case DeviceState.publish(
             {:state_reported, :alarms, alarms},
             state.device_state_server
           ) do
        :ok -> %{state | published_alarms: alarms}
        {:error, :shutting_down} -> state
        {:error, reason} -> raise "alarm publication failed: #{inspect(reason)}"
      end
    end
  end

  defp log_changes(previous, current) do
    previous_ids = MapSet.new(previous, & &1.id)
    current_ids = MapSet.new(current, & &1.id)

    Enum.each(MapSet.difference(current_ids, previous_ids), &log_transition(:set, &1))
    Enum.each(MapSet.difference(previous_ids, current_ids), &log_transition(:clear, &1))
  end

  defp log_transition(state, id) do
    alarm = public_alarm(id)
    level = if state == :set, do: alarm.level, else: :info

    Logger.log(level, "alarm #{state}: #{id}",
      alarm: true,
      alarm_id: id,
      alarm_state: state,
      alarm_level: alarm.level,
      alarm_description: alarm.description
    )
  end

  defp initial_storage_failure(options) do
    case Keyword.fetch(options, :storage_failure) do
      {:ok, active} ->
        active

      :error ->
        if Keyword.get(options, :name, __MODULE__) == __MODULE__,
          do: :persistent_term.get({__MODULE__, :storage_failure}, false),
          else: false
    end
  end

  defp notify_storage_failure(server, active) do
    GenServer.call(server, {:storage_failure, active})
  catch
    :exit, _reason -> :ok
  end

  defp public_alarm(id), do: Map.put(Map.fetch!(@catalog, id), :id, id)
  defp now(state), do: state.clock.()
  defp schedule_tick(state), do: Process.send_after(self(), :tick, state.tick_interval)
end

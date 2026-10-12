defmodule NervesGate.Indicators do
  @moduledoc """
  Three status LEDs and fixed, release-only button gestures.

  `identify/1` overrides the LEDs for five seconds, then resumes current status.
  `status/1` is read-only; `observe/1` subscribes the caller to change hints.
  Recovery runs in one bounded worker and is never automatically retried.
  """
  use GenServer
  alias NervesGate.{Alarms, Error, Network, Observations, Recovery, Remote}
  alias NervesGate.Indicators.{Button, Policy}

  @leds [:run, :user1, :user2]
  @tick_ms 125

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Identify for five seconds, rejecting overlap and unavailable LED channels."
  @spec identify(GenServer.server()) :: :ok | {:error, term()}
  def identify(server \\ __MODULE__), do: GenServer.call(server, :identify)

  @doc "Read current LED patterns, button availability and the last recovery outcome."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Subscribe to change hints; reread status after each notification."
  @spec observe(GenServer.server()) :: :ok | {:error, :unavailable}
  def observe(server \\ __MODULE__), do: Observations.subscribe_runtime(server)

  def unavailable do
    %{
      available: false,
      simulated: false,
      button: %{available: false, armed: false, feedback: "normal", last_pressed_at: nil},
      led: %{
        available: false,
        identifying: false,
        restore_pending: false,
        channels: Map.new(@leds, &{&1, false}),
        patterns: Map.put(public_patterns(Policy.normal(%{}, false, :unknown)), :run, "off"),
        error: nil
      },
      recovery: %{action: nil, status: "idle", error: nil}
    }
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Alarms.register(Keyword.get(opts, :name, __MODULE__), [:led_restore_failed, :recovery_failed])
    normal = Policy.normal(%{}, false, :unknown)

    state = %{
      name: Keyword.get(opts, :name, __MODULE__),
      adapter:
        Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :indicators_adapter)),
      recovery_adapter:
        Keyword.get(opts, :recovery_adapter, Application.get_env(:nerves_gate, :recovery_adapter)),
      remote: Keyword.get(opts, :remote, Remote),
      network: Keyword.get(opts, :network, Network),
      alarms: Keyword.get(opts, :alarms),
      clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
      poll_ms: Keyword.get(opts, :poll_ms, 5_000),
      identify_ms: Keyword.get(opts, :identify_ms, 5_000),
      recovery_ms: Keyword.get(opts, :recovery_ms, 15_000),
      button: nil,
      gesture: Button.new(),
      last_press: nil,
      normal: normal,
      patterns: normal,
      values: Map.new(@leds, &{&1, nil}),
      error: nil,
      fault: nil,
      identify_until: nil,
      worker: nil,
      recovery: %{action: nil, status: "idle", error: nil}
    }

    send(self(), :poll)
    Process.send_after(self(), :tick, @tick_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, public(state), state}
  def handle_call(:observations, _, state), do: {:reply, sources(), state}

  def handle_call(:identify, _, state) do
    {reply, state} = start_identify(state)
    {:reply, reply, render(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, @tick_ms)
    {:noreply, render(state)}
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, refresh(state)}
  end

  def handle_info(:refresh, state), do: {:noreply, refresh(state)}

  def handle_info(%PropertyTable.Event{}, state),
    do: {:noreply, state |> observations() |> render()}

  def handle_info({VintageNet, _, _, _, _}, state),
    do: {:noreply, state |> observations() |> render()}

  def handle_info(%Alarmist.Event{}, state), do: {:noreply, state |> observations() |> render()}

  def handle_info({:input_event, path, events}, %{button: %{path: path}} = state)
      when is_list(events) do
    state =
      if Enum.any?(events, &uncertain?/1) do
        %{state | gesture: Button.new()}
      else
        Enum.reduce(events, state, &button_event/2)
      end

    {:noreply, render(state)}
  end

  def handle_info({:input_event, path, :disconnect}, %{button: %{path: path}} = state),
    do: {:noreply, render(%{state | button: nil, gesture: Button.new()})}

  def handle_info({:input_event, path, _}, %{button: %{path: path}} = state),
    do: {:noreply, render(%{state | gesture: Button.new()})}

  def handle_info({:EXIT, pid, _}, %{button: %{pid: pid}} = state),
    do: {:noreply, render(%{state | button: nil, gesture: Button.new()})}

  def handle_info({ref, result}, %{worker: {%Task{ref: ref}, timer}} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(timer)
    {:noreply, recovery_complete(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: {%Task{ref: ref}, timer}} = state) do
    Process.cancel_timer(timer)
    {:noreply, recovery_complete(state, {:error, :recovery_outcome_unknown})}
  end

  def handle_info({:recovery_timeout, ref}, %{worker: {%Task{ref: ref} = task, _}} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, recovery_complete(state, {:error, :recovery_outcome_unknown})}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.worker, do: Task.shutdown(elem(state.worker, 0), :brutal_kill)
    for led <- @leds, not is_nil(state.values[led]), do: write_led(state, led, 0)
    if state.button && is_pid(state.button.pid), do: Process.exit(state.button.pid, :shutdown)
    :ok
  end

  defp refresh(state) do
    subscribe(state)

    values =
      Map.new(@leds, fn led ->
        value =
          case read_led(state, led) do
            {:ok, value} -> value
            _ -> nil
          end

        {led, value}
      end)

    %{state | values: values}
    |> connect_button()
    |> observations()
    |> render()
  end

  defp subscribe(state) do
    for server <- [state.network, state.remote], not is_nil(server) do
      safely(
        fn -> server |> GenServer.call(:observations, 100) |> Observations.subscribe() end,
        :ok
      )
    end

    safely(
      fn ->
        Alarmist.unsubscribe_all()
        Alarmist.subscribe_all()
      end,
      :ok
    )
  end

  defp observations(state) do
    remote = safely(fn -> GenServer.call(state.remote, :status, 100) end, Remote.unavailable())
    network = safely(fn -> GenServer.call(state.network, :status, 100) end, nil)
    internet = Observations.Network.internet(network).online

    alarms =
      safely(state.alarms || fn -> Alarms.indication(state.network, state.remote) end, :unknown)

    %{state | normal: Policy.normal(remote, internet, alarms)}
  end

  defp render(state) do
    now = state.clock.()
    until = if state.identify_until && now < state.identify_until, do: state.identify_until
    state = %{state | identify_until: until}
    patterns = Policy.override(state.normal, override(state, now))
    state = Enum.reduce(@leds, %{state | patterns: patterns}, &apply_led(&1, &2, now))
    fault = Enum.any?(state.values, fn {_, value} -> is_nil(value) end)
    error = if fault, do: state.error || :led_unavailable

    if state.adapter != nil and state.fault != fault,
      do: Alarms.report(:led_restore_failed, state.name, fault)

    publish(%{state | fault: fault, error: error})
  end

  defp override(%{recovery: %{status: status, action: action}}, _)
       when status in ["running", "requested"],
       do: if(action == "factory_reset", do: :reset, else: :reboot)

  defp override(state, now) do
    case Button.feedback(state.gesture, now) do
      :normal -> if(state.identify_until, do: :identify, else: :normal)
      feedback -> feedback
    end
  end

  defp apply_led(led, state, now) do
    value = Policy.value(state.patterns[led], now)

    if state.values[led] in [nil, value] do
      state
    else
      case write_led(state, led, value) do
        :ok -> %{state | values: Map.put(state.values, led, value)}
        _ -> %{state | values: Map.put(state.values, led, nil), error: :led_restore_failed}
      end
    end
  end

  defp start_identify(%{identify_until: until, recovery: %{action: action}} = state)
       when not is_nil(until) or not is_nil(action),
       do: {{:error, :operation_in_progress}, state}

  defp start_identify(state) do
    if Enum.all?(state.values, fn {_, value} -> not is_nil(value) end),
      do: {:ok, %{state | identify_until: state.clock.() + state.identify_ms}},
      else: {{:error, :led_unavailable}, state}
  end

  defp connect_button(%{button: nil, adapter: {module, context}} = state) do
    case safely(fn -> module.open_button(self(), context) end, :error) do
      {:ok, pid, path} -> %{state | button: %{pid: pid, path: path}, gesture: Button.new()}
      _ -> state
    end
  end

  defp connect_button(state), do: state

  defp uncertain?({:ev_syn, :syn_dropped, _}), do: true
  defp uncertain?({:ev_key, :key_prog1, value}), do: value not in [0, 1, 2]
  defp uncertain?(_), do: false

  defp button_event({:ev_key, :key_prog1, value}, state) do
    {gesture, action} = Button.event(value, state.clock.(), state.gesture)

    last =
      if gesture.pressed_at && is_nil(state.gesture.pressed_at),
        do: System.system_time(:millisecond),
        else: state.last_press

    state = %{state | gesture: gesture, last_press: last}
    button_action(action, state)
  end

  defp button_event(_, state), do: state
  defp button_action(:identify, state), do: elem(start_identify(state), 1)

  defp button_action(action, %{recovery: %{action: nil}} = state)
       when action in [:reboot, :factory_reset] do
    task = Task.async(fn -> Recovery.execute(state.recovery_adapter, action) end)
    timer = Process.send_after(self(), {:recovery_timeout, task.ref}, state.recovery_ms)

    %{
      state
      | worker: {task, timer},
        identify_until: nil,
        recovery: %{state.recovery | action: to_string(action), status: "running"}
    }
  end

  defp button_action(_, state), do: state

  defp recovery_complete(state, result) do
    error =
      case result do
        :ok -> nil
        {:error, reason} -> Error.from(reason)
        _ -> Error.from(:recovery_outcome_unknown)
      end

    Alarms.report(:recovery_failed, state.name, error != nil)

    recovery = %{
      state.recovery
      | status: if(error, do: "failed", else: "requested"),
        error: error
    }

    render(%{state | worker: nil, gesture: Button.new(), recovery: recovery})
  end

  defp read_led(%{adapter: {module, context}}, led),
    do: safely(fn -> module.read_led(led, context) end, {:error, :led_unavailable})

  defp read_led(_, _), do: {:error, :led_unavailable}

  defp write_led(%{adapter: {module, context}}, led, value),
    do: safely(fn -> module.write_led(led, value, context) end, {:error, :led_unavailable})

  defp write_led(_, _, _), do: {:error, :led_unavailable}

  defp safely(fun, fallback) do
    fun.()
  rescue
    ArgumentError -> fallback
  catch
    :exit, _ -> fallback
  end

  defp public(state) do
    %{
      available: state.adapter != nil,
      simulated: match?({NervesGate.Indicators.Host, _}, state.adapter),
      button: %{
        available: state.button != nil,
        armed: state.gesture.released_at != nil,
        feedback: to_string(Button.feedback(state.gesture, state.clock.())),
        last_pressed_at: state.last_press
      },
      led: %{
        available: Enum.all?(state.values, fn {_, value} -> not is_nil(value) end),
        identifying: state.identify_until != nil,
        restore_pending: state.error == :led_restore_failed,
        channels: Map.new(state.values, fn {led, value} -> {led, not is_nil(value)} end),
        patterns: public_patterns(state.patterns),
        error: state.error && Error.from(state.error)
      },
      recovery: state.recovery
    }
  end

  defp public_patterns(patterns),
    do: Map.new(patterns, fn {led, pattern} -> {led, to_string(pattern)} end)

  defp sources, do: [{Observations.table(), Observations.workflow("indicators", "status")}]

  defp publish(state) do
    for {_, path} <- sources(), do: Observations.put(path, public(state))
    state
  end
end

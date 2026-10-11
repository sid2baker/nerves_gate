defmodule NervesGate.Indicators do
  @moduledoc "One bounded identify blink and an opt-in, non-destructive button. Mode resets on restart."
  use GenServer
  alias NervesGate.{Error, Observations}

  @blink_ms 500
  @identify_ms 5_000
  @poll_ms 5_000

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def identify(server \\ __MODULE__), do: GenServer.call(server, :identify)
  def button_mode(mode, server \\ __MODULE__), do: GenServer.call(server, {:button_mode, mode})

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def observe(server \\ __MODULE__), do: Observations.subscribe_runtime(server)

  def unavailable do
    %{
      available: false,
      simulated: false,
      button: %{available: false, mode: "disabled", last_pressed_at: nil},
      led: %{available: false, identifying: false, restore_pending: false, error: nil}
    }
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      adapter:
        Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :indicators_adapter)),
      button: nil,
      mode: "disabled",
      down: false,
      last_press: nil,
      pressed_at: nil,
      led_available: false,
      blink: nil,
      restore: nil,
      error: nil,
      blink_ms: Keyword.get(opts, :blink_ms, @blink_ms),
      identify_ms: Keyword.get(opts, :identify_ms, @identify_ms)
    }

    send(self(), :poll)
    {:ok, publish(state)}
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, public(state), state}
  def handle_call(:observations, _, state), do: {:reply, sources(), state}

  def handle_call(:identify, _, state) do
    {reply, state} = start_identify(state)
    {:reply, reply, publish(state)}
  end

  def handle_call({:button_mode, "identify"}, _, %{button: nil} = state),
    do: {:reply, {:error, :button_unavailable}, state}

  def handle_call({:button_mode, mode}, _, state) when mode in ["disabled", "identify"],
    do: {:reply, :ok, publish(%{state | mode: mode})}

  def handle_call({:button_mode, _}, _, state),
    do: {:reply, {:error, :button_mode}, state}

  @impl true
  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, @poll_ms)
    state = state |> restore_led() |> refresh_led() |> connect_button()
    {:noreply, publish(state)}
  end

  def handle_info({:blink, id}, %{blink: %{id: id} = blink} = state) do
    state =
      if now() >= blink.deadline do
        finish_identify(state)
      else
        case write_led(state, 1 - blink.value) do
          :ok -> schedule_blink(%{state | blink: %{blink | value: 1 - blink.value}})
          {:error, _} -> finish_identify(%{state | error: :led_unavailable})
        end
      end

    {:noreply, publish(state)}
  end

  def handle_info({:input_event, path, events}, %{button: %{path: path}} = state)
      when is_list(events) do
    state = Enum.reduce(events, state, &button_event/2)
    {:noreply, publish(state)}
  end

  def handle_info({:input_event, path, :disconnect}, %{button: %{path: path}} = state),
    do: {:noreply, publish(%{state | button: nil, down: false})}

  def handle_info({:EXIT, pid, _}, %{button: %{pid: pid}} = state),
    do: {:noreply, publish(%{state | button: nil, down: false})}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    finish_identify(state)
    if state.button && is_pid(state.button.pid), do: Process.exit(state.button.pid, :shutdown)
    :ok
  end

  defp start_identify(%{blink: blink, restore: restore} = state)
       when not is_nil(blink) or not is_nil(restore),
       do: {{:error, :operation_in_progress}, state}

  defp start_identify(state) do
    case read_led(state) do
      {:ok, previous} ->
        state = %{state | restore: previous, error: nil}

        case write_led(state, 1 - previous) do
          :ok ->
            blink = %{
              id: make_ref(),
              deadline: now() + state.identify_ms,
              value: 1 - previous,
              timer: nil
            }

            {:ok, schedule_blink(%{state | blink: blink, led_available: true})}

          {:error, _} ->
            {{:error, :led_unavailable}, finish_identify(%{state | error: :led_unavailable})}
        end

      {:error, _} ->
        {{:error, :led_unavailable}, %{state | led_available: false, error: :led_unavailable}}
    end
  end

  defp schedule_blink(state) do
    delay = min(state.blink_ms, max(0, state.blink.deadline - now()))
    timer = Process.send_after(self(), {:blink, state.blink.id}, delay)
    %{state | blink: %{state.blink | timer: timer}}
  end

  defp finish_identify(state) do
    if state.blink, do: Process.cancel_timer(state.blink.timer)
    restore_led(%{state | blink: nil})
  end

  defp restore_led(%{blink: nil, restore: value} = state) when not is_nil(value) do
    case write_led(state, value) do
      :ok ->
        %{
          state
          | restore: nil,
            error: if(state.error == :led_restore_failed, do: nil, else: state.error)
        }

      {:error, _} ->
        %{state | led_available: false, error: :led_restore_failed}
    end
  end

  defp restore_led(state), do: state

  defp refresh_led(state) do
    %{state | led_available: match?({:ok, _}, read_led(state))}
  end

  defp connect_button(%{button: nil, adapter: {module, context}} = state) do
    case module.open_button(self(), context) do
      {:ok, pid, path} -> %{state | button: %{pid: pid, path: path}, down: false}
      {:error, _} -> state
    end
  end

  defp connect_button(state), do: state

  defp button_event({:ev_key, :key_prog1, 0}, state), do: %{state | down: false}

  defp button_event({:ev_key, :key_prog1, 1}, %{down: false} = state) do
    pressed = now()

    if is_nil(state.last_press) or pressed - state.last_press >= 1_000 do
      state = %{
        state
        | down: true,
          last_press: pressed,
          pressed_at: System.system_time(:millisecond)
      }

      {_, state} = if state.mode == "identify", do: start_identify(state), else: {:ok, state}
      state
    else
      %{state | down: true}
    end
  end

  defp button_event(_, state), do: state

  defp read_led(%{adapter: {module, context}}), do: module.read_led(context)
  defp read_led(_), do: {:error, :led_unavailable}
  defp write_led(%{adapter: {module, context}}, value), do: module.write_led(value, context)
  defp write_led(_, _), do: {:error, :led_unavailable}
  defp now, do: System.monotonic_time(:millisecond)

  defp public(state) do
    %{
      available: state.adapter != nil,
      simulated: match?({NervesGate.Indicators.Host, _}, state.adapter),
      button: %{
        available: state.button != nil,
        mode: state.mode,
        last_pressed_at: state.pressed_at
      },
      led: %{
        available: state.led_available,
        identifying: state.blink != nil,
        restore_pending: state.blink == nil and state.restore != nil,
        error: state.error && Error.from(state.error)
      }
    }
  end

  defp sources, do: [{Observations.table(), Observations.workflow("indicators", "status")}]

  defp publish(state) do
    for {_, path} <- sources(), do: Observations.put(path, public(state))
    state
  end
end

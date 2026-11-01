defmodule IotrouterExpansion.Bus do
  @moduledoc """
  One explicitly started expansion bus on the caller's assigned
  `:iotrouter_expansion` resource. It opens the UART and the resource's reset/link
  GPIOs, resets the chain, discovers cards, sends their (zero) configuration,
  starts cyclic exchange and registers the cards' endpoints.

  Starting resets the cards, so their outputs return to the card's power-on state;
  nothing else is written until an output Desire arrives. Output state is first
  learned from the cards' echo. A write sends a card's complete output state and is
  repeated every cycle until the echo matches or the deadline passes, as the stock
  agent does; an unconfirmed write is reported as unknown.

  Any bus fault stops the runtime. Restart is explicit; there is no automatic retry.
  """
  use GenServer, restart: :temporary
  alias Circuits.{GPIO, UART}
  alias IotrouterExpansion.{Card, Outputs, Protocol}

  @speed 921_600
  @max_cards 16
  @reply_timeout 100
  @reset_ms 50
  @boot_ms 500
  @first_frame_timeout 1_000
  @write_timeout 300
  @refresh_ms 1_000

  def start_link(port), do: GenServer.start_link(__MODULE__, port, name: __MODULE__)

  def status do
    case GenServer.whereis(__MODULE__) do
      nil -> %{state: :stopped}
      pid -> GenServer.call(pid, :status, 1_000)
    end
  catch
    :exit, _ -> %{state: :unavailable}
  end

  @doc false
  def write(address, channel, value),
    do: GenServer.call(__MODULE__, {:write, address, channel, value}, @write_timeout + 1_000)

  @impl true
  def init(port) do
    # Supervisor shutdown must run terminate/2 and close the handles.
    Process.flag(:trap_exit, true)
    state = %{port: port, uart: nil, reset: nil, link: nil, outputs: nil, cards: []}

    case open(state) do
      {:ok, state} ->
        try do
          initialize(state)
        rescue
          exception ->
            close(state)
            {:stop, {exception, __STACKTRACE__}}
        catch
          kind, reason ->
            close(state)
            {:stop, {kind, reason}}
        end

      {:error, reason, state} ->
        close(state)
        {:stop, reason}
    end
  end

  defp initialize(state) do
    with {:ok, cards} <- discover(state),
         :ok <- supported(cards),
         :ok <- start_exchange(state, cards),
         {:ok, frame, rest} <- first_frame(state, length(cards)),
         :ok <- register(cards),
         :ok <- UART.configure(state.uart, active: true),
         {:ok, outputs} <- start_outputs(cards) do
      state = %{state | cards: cards, outputs: outputs}
      Process.send_after(self(), :refresh, @refresh_ms)

      {:ok,
       Map.merge(state, %{
         buffer: rest,
         last_frame: System.monotonic_time(:millisecond),
         slots: frame,
         echo: echo(cards, frame),
         pending: nil,
         link?: read_link(state)
       })
       |> publish_all()}
    else
      {:error, reason} ->
        close(state)
        {:stop, reason}
    end
  end

  defp open(%{reset: nil} = state) do
    case gpio(state.port.gpios[:reset], :output, initial_value: 1) do
      {:ok, reset} -> open(%{state | reset: reset})
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp open(%{link: nil} = state) do
    case gpio(state.port.gpios[:link], :input, []) do
      {:ok, link} -> open(%{state | link: link})
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp open(%{uart: nil} = state) do
    case UART.start_link() do
      {:ok, uart} -> open(%{state | uart: uart})
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp open(state) do
    case uart_result(UART.open(state.uart, state.port.path, speed: @speed, active: false)) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp gpio(nil, _, _), do: {:error, :gpio_not_assigned}

  defp gpio(label, direction, options) do
    case GPIO.open(label, direction, options) do
      {:ok, handle} -> {:ok, handle}
      {:error, reason} -> {:error, {:gpio_unavailable, label, reason}}
    end
  end

  defp uart_result(:ok), do: :ok
  defp uart_result({:error, reason}), do: {:error, {:uart_unavailable, reason}}

  # Reset is active low; the stock agent holds the line high while running.
  defp discover(state) do
    GPIO.write(state.reset, 0)
    Process.sleep(@reset_ms)
    GPIO.write(state.reset, 1)
    Process.sleep(@boot_ms)
    UART.flush(state.uart)
    search(state, 1, [])
  end

  defp search(_, address, _) when address > @max_cards, do: {:error, :chain_end_not_found}

  defp search(state, address, cards) do
    with {:ok, func, payload} <- request(state, Protocol.search(address)),
         {:ok, %{address: ^address} = card, last?} <- Protocol.card(func, payload) do
      if last?,
        do: {:ok, Enum.reverse([card | cards])},
        else: search(state, address + 1, [card | cards])
    else
      {:error, :timeout} when cards == [] and address == 1 -> {:error, :no_cards}
      {:error, reason} -> {:error, {:search_failed, address, reason}}
      _ -> {:error, {:search_failed, address, :unexpected_reply}}
    end
  end

  defp supported(cards) do
    case Enum.reject(cards, &Card.supported?/1) do
      [] -> :ok
      unsupported -> {:error, {:unsupported_cards, unsupported}}
    end
  end

  defp start_exchange(state, cards) do
    last = List.last(cards).address

    configured =
      Enum.reduce_while(cards, :ok, fn card, :ok ->
        case acknowledged(
               state,
               Protocol.configure(card.address),
               Protocol.configure_func(),
               card.address
             ) do
          :ok -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)

    with :ok <- configured,
         do: acknowledged(state, Protocol.start(last), Protocol.start_func(), last)
  end

  defp acknowledged(state, frame, func, address) do
    case request(state, frame) do
      {:ok, reply, payload} ->
        if Protocol.ack?(reply, payload, func, address),
          do: :ok,
          else: {:error, {:not_acknowledged, func, address}}

      {:error, reason} ->
        {:error, {:not_acknowledged, func, address, reason}}
    end
  end

  defp request(state, frame) do
    # Stock discovery/configuration requests are spaced ~25 ms apart, even
    # though replies arrive in <2 ms. A reply is not proof the chain is ready
    # for the next command. Keep the response deadline separate from pacing.
    Process.sleep(Protocol.command_interval())
    with :ok <- UART.write(state.uart, frame), do: await_reply(state, <<>>, deadline())
  end

  defp await_reply(state, buffer, deadline) do
    case Protocol.reply(buffer) do
      {:ok, func, payload, _} ->
        {:ok, func, payload}

      :more ->
        remaining = deadline - System.monotonic_time(:millisecond)

        with true <- remaining > 0 || {:error, :timeout},
             {:ok, data} <- UART.read(state.uart, remaining) do
          await_reply(state, buffer <> data, deadline)
        end
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + @reply_timeout

  defp register(cards) do
    cards
    |> Enum.flat_map(&Card.inputs/1)
    |> Enum.reduce_while(:ok, fn definition, :ok ->
      case NervesGateSDK.IO.register_input(definition) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:registration_failed, definition.id, reason}}}
      end
    end)
  end

  defp start_outputs(cards) do
    channels = Card.output_channels(cards)

    case NervesGateSDK.Output.start_link(Outputs, Enum.flat_map(cards, &Card.outputs/1), channels) do
      {:ok, pid} -> {:ok, pid}
      {:error, reason} -> {:error, {:outputs_start_failed, reason}}
    end
  end

  defp first_frame(state, count) do
    deadline = System.monotonic_time(:millisecond) + @first_frame_timeout
    first_frame(state, count, <<>>, deadline)
  end

  defp first_frame(state, count, buffer, deadline) do
    case Protocol.cyclic(buffer, count) do
      {frames, rest} when frames != [] ->
        {:ok, List.last(frames), rest}

      {[], rest} ->
        remaining = deadline - System.monotonic_time(:millisecond)

        with true <- remaining > 0 || {:error, :no_cyclic_data},
             {:ok, data} <- UART.read(state.uart, remaining) do
          first_frame(state, count, rest <> data, deadline)
        end
    end
  end

  @impl true
  def handle_call(:status, _, state) do
    cards =
      for {card, slot} <- Enum.zip(state.cards, state.slots),
          do:
            Map.merge(card, %{
              id: Card.id(card),
              name: Card.name(card),
              values: Card.readings(card, slot)
            })

    {:reply, %{state: :running, resource: state.port.id, link?: state.link?, cards: cards}, state}
  end

  # One SDK Output runtime serializes all channels. Reject any other concurrent
  # setter rather than merging two full-card states from different snapshots.
  def handle_call({:write, _, _, _}, _, %{pending: pending} = state) when pending != nil,
    do: {:reply, {:error, :write_in_progress}, state}

  def handle_call({:write, address, channel, value}, from, state) do
    echo = state.echo[address]

    cond do
      System.monotonic_time(:millisecond) - state.last_frame > @reply_timeout ->
        {:reply, {:error, :cyclic_data_stale}, state}

      echo == nil ->
        {:reply, {:error, :unknown_card}, state}

      not is_integer(channel) or channel < 0 or channel >= length(echo) or not is_boolean(value) ->
        {:reply, {:error, :invalid_channel_value}, state}

      Enum.at(echo, channel) == value ->
        {:reply, :ok, state}

      true ->
        target = List.replace_at(echo, channel, value)

        pending = %{
          from: from,
          address: address,
          channel: channel,
          value: value,
          frame: Protocol.write(address, target),
          until: System.monotonic_time(:millisecond) + @write_timeout
        }

        {:noreply, resend(%{state | pending: pending})}
    end
  end

  @impl true
  def handle_info({:circuits_uart, _, data}, state) when is_binary(data) do
    {frames, rest} = Protocol.cyclic(state.buffer <> data, length(state.cards))
    {:noreply, Enum.reduce(frames, %{state | buffer: rest}, &frame/2) |> resend()}
  end

  def handle_info({:circuits_uart, _, {:error, reason}}, state),
    do: {:stop, {:uart_failed, reason}, state}

  def handle_info(:refresh, state) do
    if System.monotonic_time(:millisecond) - state.last_frame > @first_frame_timeout do
      {:stop, :cyclic_data_lost, state}
    else
      Process.send_after(self(), :refresh, @refresh_ms)

      for id <- Map.keys(Card.output_channels(state.cards)),
          do: NervesGateSDK.Output.reapply(state.outputs, id)

      {:noreply, %{state | link?: read_link(state)} |> publish_all()}
    end
  end

  def handle_info({:EXIT, pid, reason}, %{outputs: pid} = state),
    do: {:stop, {:outputs_exit, reason}, state}

  def handle_info({:EXIT, pid, reason}, %{uart: pid} = state),
    do: {:stop, {:uart_exit, reason}, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state), do: close(state)

  defp frame(slots, state) do
    previous = state.slots

    state = %{
      state
      | slots: slots,
        echo: echo(state.cards, slots),
        last_frame: System.monotonic_time(:millisecond)
    }

    for {card, old, new} <- Enum.zip([state.cards, previous, slots]),
        old != new,
        {id, value} <- Card.readings(card, new),
        do: NervesGateSDK.IO.publish(id, value)

    confirm(state)
  end

  defp confirm(%{pending: nil} = state), do: state

  defp confirm(%{pending: pending} = state) do
    if Enum.at(state.echo[pending.address], pending.channel) == pending.value do
      GenServer.reply(pending.from, :ok)
      %{state | pending: nil}
    else
      state
    end
  end

  # Repeat only this setter, only until its deadline. Expiry drops the whole
  # target so later channel writes start from the current echo, not old Desires.
  defp resend(%{pending: nil} = state), do: state

  defp resend(%{pending: pending} = state) do
    if System.monotonic_time(:millisecond) >= pending.until do
      GenServer.reply(pending.from, {:error, :not_confirmed})
      %{state | pending: nil}
    else
      :ok = UART.write(state.uart, pending.frame)
      state
    end
  end

  defp echo(cards, slots) do
    for {%{do: count} = card, slot} <- Enum.zip(cards, slots),
        count > 0,
        into: %{},
        do: {card.address, Protocol.channels(slot, count)}
  end

  defp publish_all(state) do
    for {card, slot} <- Enum.zip(state.cards, state.slots),
        {id, value} <- Card.readings(card, slot),
        do: NervesGateSDK.IO.publish(id, value)

    state
  end

  defp read_link(%{link: nil}), do: nil
  defp read_link(state), do: GPIO.read(state.link) == 1

  defp close(state) do
    if state.outputs && Process.alive?(state.outputs), do: GenServer.stop(state.outputs)
    if state.uart && Process.alive?(state.uart), do: UART.stop(state.uart)
    if state.link, do: GPIO.close(state.link)
    if state.reset, do: GPIO.close(state.reset)
    :ok
  end
end

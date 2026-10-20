defmodule NervesGate.Buses do
  @moduledoc """
  CAN and RS485 ownership, SDK access and bounded diagnostics on allowlisted ports.

  SDK serial claims exclude diagnostics and are released on owner exit. CAN
  receive sockets are shared by process-owned subscriptions. SDK sends never
  configure an interface or leave listen-only mode.

  ## Commands

  `configure/3`, `capture/2` and `modbus_read/3` return `:ok` when accepted,
  or `{:error, reason}`. CAN configuration and diagnostics complete asynchronously;
  RS485 configuration changes its in-memory opt-in immediately. Only one worker
  runs at a time. Read `status/1` for completion, errors and results.

  ## Queries and notifications

  `status/1` returns detected ports, the current operation and the last result.
  `observe/1` subscribes the caller to changes. Idle observations never open UARTs
  or transmit traffic. Serial opt-in and results reset on restart.
  The optional server argument defaults to this module.

  `:bus_port_unavailable` reports a missing, known enabled port. CAN enablement
  comes from observations; RS485 from explicit opt-in. Missing observations never
  erase known enablement. An observed return or removal of opt-in clears the
  condition. After restart, unknown CAN state preserves the previous alarm.
  """
  use GenServer
  alias NervesGate.{Alarms, Error, Observations}
  alias NervesGate.Buses.{Policy, Serial}
  alias NervesGate.Linux.CAN
  alias NervesGateSDK.Events.Event

  @serial_ports %{"rs485_1" => "ttyS3", "rs485_2" => "ttyS4"}

  @doc false
  def sdk(operation, arguments), do: GenServer.call(__MODULE__, {:sdk, operation, arguments})

  @doc false
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Configure can0/can1 or opt ttyS3/ttyS4 in or out of diagnostics.

  Params use string keys: `"enabled"` is required; CAN also requires a supported
  `"bitrate"` and defaults to listen-only mode. Administrators can explicitly set
  `"listen_only" => false` to permit SDK transmission; passive diagnostics still
  require listen-only mode. RS485 uses fixed 9600 8N1.
  """
  @spec configure(String.t(), map(), GenServer.server()) :: :ok | {:error, term()}
  def configure(port, params, server \\ __MODULE__),
    do: GenServer.call(server, {:configure, port, params})

  @doc "Start receive-only capture on an enabled port: up to five seconds, 200 frames or 4096 bytes."
  @spec capture(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def capture(port, server \\ __MODULE__), do: GenServer.call(server, {:capture, port})

  @doc """
  Request one authorized Modbus RTU read on ttyS3/ttyS4, without retry.

  String-keyed params: `"authorized"` must be true, `"unit"` 1–247,
  `"function"` 3 or 4, `"address"` zero-based 0–65535, and `"count"` 1–32
  without crossing address 65535. The operator must ensure no other master is active.
  """
  @spec modbus_read(String.t(), map(), GenServer.server()) :: :ok | {:error, term()}
  def modbus_read(port, params, server \\ __MODULE__),
    do: GenServer.call(server, {:modbus_read, port, params})

  @doc "Subscribe the caller to bus status/result hints; reread status on notification."
  @spec observe(GenServer.server()) :: :ok | {:error, :unavailable}
  def observe(server \\ __MODULE__), do: Observations.subscribe_runtime(server)

  @doc "Read ports, operation, result and error. An accepted operation finishes when operation is nil."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc false
  def unavailable,
    do: %{available: false, simulated: false, ports: [], operation: nil, result: nil, error: nil}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Alarms.register(Keyword.get(opts, :name, __MODULE__), [:bus_port_unavailable])

    state = %{
      adapter: Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :buses_adapter)),
      id: inspect(Keyword.get(opts, :name, __MODULE__) || self()),
      name: Keyword.get(opts, :name, __MODULE__),
      ports: [],
      enabled: %{"ttyS3" => false, "ttyS4" => false},
      worker: nil,
      operation: nil,
      result: nil,
      error: nil,
      timeout: Keyword.get(opts, :timeout, 6_500),
      claims: %{},
      subscribers: %{},
      monitors: %{},
      sockets: %{}
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, public(state), state}
  def handle_call(:observations, _, state), do: {:reply, sources(state), state}

  def handle_call({:sdk, operation, arguments}, {pid, _}, state),
    do: sdk_call(operation, arguments, pid, state)

  def handle_call({:configure, name, params}, _, state) do
    with {:ok, params} <- Policy.configure(name, params),
         :ok <- unclaimed(state, name),
         {:ok, port} <- Policy.port(public(state), name) do
      configure_port(port, params, state)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:capture, name}, _, state) do
    with :ok <- unclaimed(state, name),
         {:ok, port} <- Policy.port(public(state), name),
         :ok <- Policy.capture(port) do
      {:reply, :ok, start(state, :capture, name, %{})}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:modbus_read, name, params}, _, state) do
    with {:ok, params} <- Policy.modbus(name, params),
         :ok <- unclaimed(state, name),
         {:ok, port} <- Policy.port(public(state), name),
         :ok <- Policy.capture(port) do
      {:reply, :ok, start(state, :modbus_read, name, params)}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{worker: {%Task{ref: ref}, _}} = state) do
    {:noreply, complete(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: {%Task{ref: ref}, _}} = state),
    do: {:noreply, complete(state, {:error, :bus_failed})}

  def handle_info({:timeout, ref}, %{worker: {%Task{ref: ref} = task, _}} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, complete(state, {:error, :bus_timeout})}
  end

  def handle_info(:poll, state) do
    Process.send_after(self(), :poll, 5_000)
    state = if state.worker, do: state, else: refresh(state)
    {:noreply, state |> reconnect_can() |> publish()}
  end

  def handle_info({:DOWN, ref, :process, pid, _}, state) do
    if state.monitors[pid] == ref,
      do: {:noreply, owner_down(state, pid)},
      else: {:noreply, state}
  end

  def handle_info({:circuits_uart, uart, data}, state) when is_binary(data) do
    case Enum.find(state.claims, fn {_, owner} -> owner.uart == uart end) do
      {_claim, owner} -> send(owner.pid, %Event{topic: {:rs485, owner.port}, value: data})
      nil -> :ok
    end

    {:noreply, state}
  end

  def handle_info({:circuits_uart, uart, {:error, _}}, state),
    do: {:noreply, release_uart(state, uart)}

  def handle_info({:EXIT, uart, _}, state), do: {:noreply, release_uart(state, uart)}
  def handle_info({:sdk_can_read, socket}, state), do: {:noreply, receive_can(state, socket)}

  def handle_info({:"$socket", socket, :select, _}, state),
    do: {:noreply, receive_can(state, socket)}

  def handle_info({:"$socket", socket, :abort, _}, state),
    do: {:noreply, close_can(state, socket)}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    if state.worker do
      {task, _} = state.worker
      Task.shutdown(task, :brutal_kill)
    end

    for {_, socket} <- state.sockets, do: :socket.close(socket)
    for {_, claim} <- state.claims, do: stop_uart(claim.uart)
    :ok
  end

  defp sdk_call(:can_interfaces, [], _, state) do
    ports =
      for %{transport: "can"} = port <- state.ports do
        %NervesGateSDK.CAN.Interface{
          id: port.name,
          state:
            cond do
              not port.present -> :unavailable
              port.up -> :up
              true -> :down
            end,
          bitrate: port.bitrate,
          listen_only?: port.listen_only != false
        }
      end

    {:reply, {:ok, ports}, state}
  end

  defp sdk_call(:can_send, [id, frame], _, state) when id in ["can0", "can1"] do
    result =
      with :ok <- hardware(state),
           true <- NervesGateSDK.CAN.Frame.valid?(frame),
           {:ok, _} <- Policy.port(public(state), id) do
        CAN.transmit(id, frame)
      else
        false -> {:error, :invalid_frame}
        error -> error
      end

    {:reply, result, state}
  end

  defp sdk_call(:can_subscribe, [id], pid, state) when id in ["can0", "can1"] do
    with :ok <- hardware(state),
         {:ok, %{up: true}} <- Policy.port(public(state), id),
         {:ok, state} <- open_can(state, id) do
      subscribers = Map.update(state.subscribers, id, MapSet.new([pid]), &MapSet.put(&1, pid))
      {:reply, :ok, monitor(%{state | subscribers: subscribers}, pid)}
    else
      {:ok, _} -> {:reply, {:error, :interface_unavailable}, state}
      error -> {:reply, error, state}
    end
  end

  defp sdk_call(:can_unsubscribe, [id], pid, state) when id in ["can0", "can1"] do
    subscribers = Map.update(state.subscribers, id, MapSet.new(), &MapSet.delete(&1, pid))
    state = %{state | subscribers: subscribers} |> close_unused_can() |> unmonitor_unused(pid)
    {:reply, :ok, state}
  end

  defp sdk_call(:rs485_ports, [], _, state) do
    ports =
      for {id, name} <- Enum.sort(@serial_ports) do
        %NervesGateSDK.RS485.Port{
          id: id,
          available?:
            hardware(state) == :ok and Enum.any?(state.ports, &(&1.name == name and &1.present)),
          claimed?: unclaimed(state, name) != :ok or match?(%{port: ^name}, state.operation)
        }
      end

    {:reply, {:ok, ports}, state}
  end

  defp sdk_call(:rs485_claim, [id], pid, state) when is_map_key(@serial_ports, id) do
    name = @serial_ports[id]

    with :ok <- hardware(state),
         :ok <- unclaimed(state, name),
         {:ok, _} <- Policy.port(public(state), name),
         {:ok, uart} <- Serial.open("/dev/" <> name, true) do
      ref = make_ref()
      claim = %{pid: pid, port: id, name: name, uart: uart}
      {:reply, {:ok, ref}, monitor(%{state | claims: Map.put(state.claims, ref, claim)}, pid)}
    else
      error -> {:reply, error, state}
    end
  end

  defp sdk_call(:rs485_write, [claim, data], pid, state)
       when is_binary(data) and byte_size(data) <= 4096 do
    case state.claims[claim] do
      %{pid: ^pid, uart: uart} ->
        result =
          try do
            Circuits.UART.write(uart, data, 500)
          catch
            :exit, _ -> {:error, :port_unavailable}
          end

        state = if result == :ok, do: state, else: release(state, claim)
        {:reply, result, state}

      _ ->
        {:reply, {:error, :not_owner}, state}
    end
  end

  defp sdk_call(:rs485_release, [claim], pid, state) do
    case state.claims[claim] do
      %{pid: ^pid} -> {:reply, :ok, release(state, claim)}
      _ -> {:reply, {:error, :not_owner}, state}
    end
  end

  defp sdk_call(_, _, _, state), do: {:reply, {:error, :invalid_request}, state}

  defp hardware(%{adapter: {NervesGate.Buses.EC100, _}}), do: :ok
  defp hardware(_), do: {:error, :bus_unsupported}

  defp unclaimed(state, name) do
    if Enum.any?(state.claims, fn {_, claim} -> claim.name == name end),
      do: {:error, :port_claimed},
      else: :ok
  end

  defp monitor(state, pid),
    do: %{state | monitors: Map.put_new_lazy(state.monitors, pid, fn -> Process.monitor(pid) end)}

  defp unmonitor_unused(state, pid) do
    used? =
      Enum.any?(state.claims, fn {_, claim} -> claim.pid == pid end) or
        Enum.any?(state.subscribers, fn {_, pids} -> MapSet.member?(pids, pid) end)

    if used? do
      state
    else
      if ref = state.monitors[pid], do: Process.demonitor(ref, [:flush])
      %{state | monitors: Map.delete(state.monitors, pid)}
    end
  end

  defp release(state, ref) do
    {claim, claims} = Map.pop!(state.claims, ref)
    stop_uart(claim.uart)
    %{state | claims: claims} |> unmonitor_unused(claim.pid)
  end

  defp release_uart(state, uart) do
    case Enum.find(state.claims, fn {_, claim} -> claim.uart == uart end) do
      {ref, _} -> release(state, ref)
      nil -> state
    end
  end

  defp stop_uart(uart) do
    Circuits.UART.stop(uart)
  catch
    :exit, _ -> :ok
  end

  defp open_can(state, id) do
    if Map.has_key?(state.sockets, id) do
      {:ok, state}
    else
      with {:ok, socket} <- CAN.open(id) do
        send(self(), {:sdk_can_read, socket})
        {:ok, %{state | sockets: Map.put(state.sockets, id, socket)}}
      end
    end
  end

  defp owner_down(state, pid) do
    claims = for {claim, %{pid: ^pid}} <- state.claims, do: claim
    state = Enum.reduce(claims, state, &release(&2, &1))
    subscribers = Map.new(state.subscribers, fn {id, pids} -> {id, MapSet.delete(pids, pid)} end)

    close_unused_can(%{
      state
      | subscribers: subscribers,
        monitors: Map.delete(state.monitors, pid)
    })
  end

  defp receive_can(state, socket) do
    case Enum.find(state.sockets, fn {_, value} -> value == socket end) do
      {id, _} -> receive_can(state, id, socket, :socket.recv(socket, 16, :nowait))
      nil -> state
    end
  end

  defp receive_can(state, id, socket, {:ok, packet}) do
    frame = CAN.decode_frame(packet)

    for pid <- Map.get(state.subscribers, id, MapSet.new()),
        frame,
        do: send(pid, %Event{topic: {:can, id}, value: frame})

    # One frame per mailbox turn; control/owner-death messages cannot starve.
    send(self(), {:sdk_can_read, socket})
    state
  end

  defp receive_can(state, _id, _socket, {:select, _}), do: state
  defp receive_can(state, _id, socket, {:error, _}), do: close_can(state, socket)

  defp close_can(state, socket) do
    :socket.close(socket)
    %{state | sockets: Map.reject(state.sockets, fn {_, value} -> value == socket end)}
  end

  defp close_unused_can(state) do
    Enum.reduce(state.sockets, state, fn {id, socket}, state ->
      if MapSet.size(Map.get(state.subscribers, id, MapSet.new())) == 0,
        do: close_can(state, socket),
        else: state
    end)
  end

  defp reconnect_can(state) do
    wanted =
      for {id, pids} <- state.subscribers,
          MapSet.size(pids) > 0,
          Enum.any?(state.ports, &(&1.name == id and &1.present and &1.up)),
          do: id

    Enum.reduce(wanted, state, fn id, state ->
      case open_can(state, id) do
        {:ok, state} -> state
        _ -> state
      end
    end)
  end

  defp configure_port(%{name: name, transport: "rs485"}, params, state) do
    enabled = Map.put(state.enabled, name, params.enabled)
    {:reply, :ok, %{state | enabled: enabled, error: nil, result: nil} |> refresh() |> publish()}
  end

  defp configure_port(%{name: name}, params, state),
    do: {:reply, :ok, start(state, :configure, name, params)}

  defp start(state, operation, name, params) do
    {module, context} = state.adapter
    task = Task.async(fn -> module.execute(operation, name, params, context) end)
    timer = Process.send_after(self(), {:timeout, task.ref}, state.timeout)

    publish(%{
      state
      | worker: {task, timer},
        operation: %{kind: to_string(operation), port: name},
        result: nil,
        error: nil
    })
  end

  defp complete(state, outcome) do
    {task, timer} = state.worker
    Process.demonitor(task.ref, [:flush])
    Process.cancel_timer(timer)

    {result, error} =
      case outcome do
        :ok ->
          {nil, nil}

        {:ok, data} ->
          {Map.merge(state.operation, %{
             data: data,
             completed_at: System.system_time(:millisecond)
           }), nil}

        {:error, reason} ->
          {nil, failure(reason)}
      end

    %{state | worker: nil, operation: nil, result: result, error: error}
    |> refresh()
    |> publish()
  end

  defp failure({:modbus_exception, code}),
    do:
      Error.new(
        "modbus_exception",
        "Device returned Modbus exception #{code}. No retry was sent."
      )

  defp failure(reason)
       when reason in [
              :modbus_response,
              :modbus_timeout,
              :serial_busy,
              :can_not_passive,
              :bus_timeout,
              :bus_failed
            ],
       do: Error.from(reason)

  defp failure(_), do: Error.from(:bus_failed)

  defp refresh(%{adapter: nil} = state), do: state

  defp refresh(state) do
    {module, context} = state.adapter

    observed = module.snapshot(context)

    enabled =
      Enum.reduce(observed, state.enabled, fn
        %{transport: "can", present: true, name: name, enabled: enabled}, known ->
          Map.put(known, name, enabled)

        _, known ->
          known
      end)

    ports =
      Enum.map(observed, fn port ->
        if port.transport == "rs485",
          do: %{port | enabled: Map.fetch!(enabled, port.name)},
          else: port
      end)

    %{state | ports: ports, enabled: enabled}
  end

  defp public(state),
    do: %{
      available: state.adapter != nil,
      simulated: match?({NervesGate.Buses.Host, _}, state.adapter),
      ports: state.ports,
      operation: state.operation,
      result: state.result,
      error: state.error
    }

  defp sources(state), do: [{Observations.table(), Observations.workflow("buses", state.id)}]

  defp port_fault(%{adapter: nil}), do: false

  defp port_fault(state) do
    present = for %{name: name, present: true} <- state.ports, do: name

    cond do
      Enum.any?(state.enabled, fn {name, enabled} -> enabled and name not in present end) -> true
      Enum.any?(Policy.ports(), &(not Map.has_key?(state.enabled, &1))) -> nil
      true -> false
    end
  end

  defp publish(state) do
    Alarms.report(:bus_port_unavailable, state.name, port_fault(state))
    for {_, path} <- sources(state), do: Observations.put(path, public(state))
    state
  end
end

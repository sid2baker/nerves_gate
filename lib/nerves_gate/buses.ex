defmodule NervesGate.Buses do
  @moduledoc """
  Bounded CAN and RS485 diagnostics on allowlisted ports.

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
  alias NervesGate.Buses.Policy

  @doc false
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc """
  Configure can0/can1 or opt ttyS3/ttyS4 in or out of diagnostics.

  Params use string keys: `"enabled"` is required; CAN also requires a supported
  `"bitrate"` and always uses listen-only mode. RS485 uses fixed 9600 8N1.
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
      timeout: Keyword.get(opts, :timeout, 6_500)
    }

    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, public(state), state}
  def handle_call(:observations, _, state), do: {:reply, sources(state), state}

  def handle_call({:configure, name, params}, _, state) do
    with {:ok, params} <- Policy.configure(name, params),
         {:ok, port} <- Policy.port(public(state), name) do
      configure_port(port, params, state)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:capture, name}, _, state) do
    with {:ok, port} <- Policy.port(public(state), name),
         :ok <- Policy.capture(port) do
      {:reply, :ok, start(state, :capture, name, %{})}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:modbus_read, name, params}, _, state) do
    with {:ok, params} <- Policy.modbus(name, params),
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
    {:noreply, publish(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{worker: {task, _}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

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

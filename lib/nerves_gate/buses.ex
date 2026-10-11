defmodule NervesGate.Buses do
  @moduledoc "One bounded bus operation at a time. No automatic traffic, persisted intent or replay."
  use GenServer
  alias NervesGate.Buses.Policy
  alias NervesGate.{Error, Observations}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def configure(port, params, server \\ __MODULE__),
    do: GenServer.call(server, {:configure, port, params})

  def capture(port, server \\ __MODULE__), do: GenServer.call(server, {:capture, port})

  def modbus_read(port, params, server \\ __MODULE__),
    do: GenServer.call(server, {:modbus_read, port, params})

  def observe(server \\ __MODULE__), do: Observations.subscribe_runtime(server)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  def unavailable,
    do: %{available: false, simulated: false, ports: [], operation: nil, result: nil, error: nil}

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      adapter: Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :buses_adapter)),
      id: inspect(Keyword.get(opts, :name, __MODULE__) || self()),
      ports: [],
      serial: MapSet.new(),
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
    serial =
      if params.enabled,
        do: MapSet.put(state.serial, name),
        else: MapSet.delete(state.serial, name)

    {:reply, :ok, %{state | serial: serial, error: nil, result: nil} |> refresh() |> publish()}
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

    ports =
      Enum.map(module.snapshot(context), fn port ->
        if port.transport == "rs485",
          do: %{port | enabled: MapSet.member?(state.serial, port.name)},
          else: port
      end)

    %{state | ports: ports}
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

  defp publish(state) do
    for {_, path} <- sources(state), do: Observations.put(path, public(state))
    state
  end
end

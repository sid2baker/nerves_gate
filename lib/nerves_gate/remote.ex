defmodule NervesGate.Remote do
  @moduledoc """
  One bounded Tailscale operation at a time. The daemon owns preferences and
  identity; this process only tracks the current request and its public result.
  Restart observes the daemon, never replays a mutation.
  """
  use GenServer
  alias NervesGate.Observations
  alias NervesGate.Remote.{Adapter, Policy}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def login_url(server \\ __MODULE__), do: GenServer.call(server, :login_url)

  def command(operation, params, server \\ __MODULE__),
    do: GenServer.call(server, {:command, operation, params})

  def observe(server \\ __MODULE__), do: Observations.subscribe_runtime(server)
  defdelegate unavailable(), to: Policy
  defdelegate validate(operation, params), to: Policy

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    state = %{
      id: inspect(Keyword.get(opts, :name, __MODULE__) || self()),
      adapter: Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :remote_adapter)),
      worker: nil,
      operation: nil,
      error: nil,
      poll_ms: Keyword.get(opts, :poll_ms, 1000),
      timeout: Keyword.get(opts, :timeout, 40_000)
    }

    Observations.subscribe(sources(state))
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _, state), do: {:reply, snapshot(state), state}
  def handle_call(:observations, _, state), do: {:reply, sources(state), state}

  def handle_call(:login_url, _, state) do
    # Explicit private read: never enters observations, state, signals or logs.
    {:reply, state.adapter |> Adapter.login_url() |> Policy.login_url(), state}
  end

  def handle_call({:command, operation, params}, _, state) do
    with :ok <- Policy.available(snapshot(state)),
         {:ok, params} <- Policy.validate(operation, params) do
      task = Task.async(fn -> Adapter.execute(state.adapter, operation, params) end)
      timer = Process.send_after(self(), {:timeout, task.ref}, state.timeout)
      state = %{state | worker: {task, timer}, operation: Atom.to_string(operation), error: nil}
      {:reply, :ok, publish(state)}
    else
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{worker: {%Task{ref: ref}, _}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: {%Task{ref: ref}, _}} = state),
    do: {:noreply, complete(state, {:error, :outcome_unknown})}

  def handle_info({:timeout, ref}, %{worker: {%Task{ref: ref} = task, _}} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, complete(state, {:error, :timeout})}
  end

  def handle_info(:poll, state) do
    Observations.subscribe(sources(state))
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, publish(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{worker: {task, _}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  defp complete(state, result) do
    {_, timer} = state.worker
    Process.cancel_timer(timer)
    publish(%{state | worker: nil, operation: nil, error: Policy.result_error(result)})
  end

  defp snapshot(state) do
    state.adapter
    |> Adapter.snapshot()
    |> Policy.sanitize()
    |> Map.merge(%{operation: state.operation, error: state.error})
  end

  defp publish(state) do
    Observations.put(path(state), :erlang.phash2(snapshot(state)))
    state
  end

  defp sources(state),
    do: [{Observations.table(), path(state)} | Observations.sources(state.adapter)]

  defp path(state), do: Observations.workflow("remote", state.id)
end

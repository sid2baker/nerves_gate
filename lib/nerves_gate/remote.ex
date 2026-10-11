defmodule NervesGate.Remote do
  @moduledoc """
  One bounded Tailscale operation at a time. The daemon owns preferences and
  identity; this process only tracks the current request and its public result.
  Restart observes the daemon, never replays a mutation.
  """
  use GenServer
  alias NervesGate.Observations
  alias NervesGate.Remote.{Adapter, Policy, Sharing}

  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)
  def login_url(server \\ __MODULE__), do: GenServer.call(server, :login_url)

  def command(operation, params, server \\ __MODULE__),
    do: GenServer.call(server, {:command, operation, params})

  def sharing(operation, params, server \\ __MODULE__),
    do: GenServer.call(server, {:sharing, operation, params}, 45_000)

  def observe(server \\ __MODULE__), do: Observations.subscribe_runtime(server)
  defdelegate unavailable(), to: Policy
  defdelegate validate(operation, params), to: Policy

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    adapter = Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :remote_adapter))

    state = %{
      sharing: Map.get(Adapter.snapshot(adapter), :sharing, Policy.unavailable().sharing),
      waiting: nil,
      route: nil,
      id: inspect(Keyword.get(opts, :name, __MODULE__) || self()),
      adapter: adapter,
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

  def handle_call({:sharing, operation, params}, from, state) do
    with :ok <- Policy.available(snapshot(state)),
         :ok <- sharing_allowed(operation, params, snapshot(state)) do
      task = Task.async(fn -> Adapter.execute(state.adapter, operation, params) end)
      timer = Process.send_after(self(), {:timeout, task.ref}, state.timeout)

      state = %{
        state
        | worker: {task, timer},
          operation: Atom.to_string(operation),
          waiting: from,
          route: params[:route],
          error: nil
      }

      {:noreply, publish(state)}
    else
      error -> {:reply, error, state}
    end
  end

  defp sharing_allowed(:sharing_enable, %{route: route, scope: scope}, remote) do
    with :ok <- Sharing.known(remote),
         :ok <- Sharing.supported(remote),
         true <- Sharing.matches?(route, scope),
         {:ok, _} <-
           NervesGate.Remote.Routes.change(
             :sharing_enable,
             %{route: route, scope: scope},
             remote.advertised_routes
           ) do
      :ok
    else
      false -> {:error, :sharing_route}
      error -> error
    end
  end

  defp sharing_allowed(:sharing_disable, %{route: route}, remote) do
    with {:ok, _} <- Sharing.decode(route),
         true <- route in ((remote.advertised_routes || []) ++ remote.sharing.uncertain) do
      :ok
    else
      _ -> {:error, :sharing_route}
    end
  end

  defp sharing_allowed(:sharing_sync, _, %{sharing: %{uncertain: []}}), do: :ok
  defp sharing_allowed(_, _, _), do: {:error, :sharing_unknown}

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
    state = finish_sharing(state, result)

    publish(%{
      state
      | worker: nil,
        operation: nil,
        waiting: nil,
        route: nil,
        error: Policy.result_error(result)
    })
  end

  defp finish_sharing(%{waiting: nil} = state, _), do: state

  defp finish_sharing(state, result) do
    case result do
      {:ok, routes} when is_list(routes) ->
        GenServer.reply(state.waiting, {:ok, routes})
        uncertain = List.delete(state.sharing.uncertain, state.route)
        %{state | sharing: %{ready: true, uncertain: uncertain}}

      _ ->
        GenServer.reply(state.waiting, {:error, :sharing_unknown})
        uncertain = Enum.uniq(state.sharing.uncertain ++ List.wrap(state.route))
        %{state | sharing: %{ready: state.route != nil, uncertain: uncertain}}
    end
  end

  defp snapshot(state) do
    state.adapter
    |> Adapter.snapshot()
    |> Policy.sanitize()
    |> Map.merge(%{operation: state.operation, error: state.error, sharing: state.sharing})
  end

  defp publish(state) do
    Observations.put(path(state), :erlang.phash2(snapshot(state)))
    state
  end

  defp sources(state),
    do: [{Observations.table(), path(state)} | Observations.sources(state.adapter)]

  defp path(state), do: Observations.workflow("remote", state.id)
end

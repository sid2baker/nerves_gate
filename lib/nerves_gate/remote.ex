defmodule NervesGate.Remote do
  @moduledoc """
  Tailscale connection and device-name control.

  ## Commands

  `connect/2`, `configure/2` and `disconnect/1` return `:ok` when accepted,
  or `{:error, reason}`. Only one daemon operation runs at a time. Acceptance
  does not mean completion: read `status/1` for `:operation` and `:error`.

  ## Queries and notifications

  `status/1` returns sanitized daemon observations. `login_url/1` is a private
  query; its result never enters status or notifications. Subscribe with
  `observe/1` before reading, then reread when properties change.

  The optional server argument defaults to this module. The daemon retains
  identity and preferences across process restarts; commands are not replayed.

  `:remote_unavailable` reports daemon loss after a connect request or an active
  authentication/connection observation. An available daemon clears it, including
  while offline or awaiting approval. Stopped/unconfigured connections do not
  require a daemon for this alarm. Unknown startup observations preserve an old
  report; no connection intent is persisted here.
  """
  use GenServer
  alias NervesGate.{Alarms, Observations}
  alias NervesGate.Remote.{Adapter, Policy, Sharing}

  @doc false
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Request connection or enrollment. Hostnames are 1–63 letters, numbers or hyphens."
  @spec connect(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def connect(hostname, server \\ __MODULE__),
    do: command(:connect, %{"hostname" => hostname}, server)

  @doc "Request a hostname change without changing connection intent; preserves omitted preferences."
  @spec configure(String.t(), GenServer.server()) :: :ok | {:error, term()}
  def configure(hostname, server \\ __MODULE__),
    do: command(:configure, %{"hostname" => hostname}, server)

  @doc "Request Tailscale down without logging out. May disconnect a caller using the VPN."
  @spec disconnect(GenServer.server()) :: :ok | {:error, term()}
  def disconnect(server \\ __MODULE__), do: command(:disconnect, %{}, server)

  @doc "Read daemon observations and the current operation/error. Never returns an enrollment URL."
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc "Read the validated HTTPS enrollment URL, or nil. Do not log or broadcast it."
  @spec login_url(GenServer.server()) :: String.t() | nil
  def login_url(server \\ __MODULE__), do: GenServer.call(server, :login_url)

  @doc "Subscribe the caller to property-change hints; read status afterward and on each notification."
  @spec observe(GenServer.server()) :: :ok | {:error, :unavailable}
  def observe(server \\ __MODULE__), do: Observations.subscribe_runtime(server)

  # Route mutations must hold Network's LAN worker. Called by Network, not clients.
  @doc false
  def sharing(operation, params, server \\ __MODULE__),
    do: GenServer.call(server, {:sharing, operation, params}, 45_000)

  @doc false
  defdelegate unavailable(), to: Policy

  defp command(operation, params, server),
    do: GenServer.call(server, {:command, operation, params})

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    adapter = Keyword.get(opts, :adapter, Application.fetch_env!(:nerves_gate, :remote_adapter))

    state = %{
      name: Keyword.get(opts, :name, __MODULE__),
      enabled: nil,
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

  defp sharing_allowed(:sharing_enable, params, remote) do
    with :ok <- Sharing.known(remote),
         {:ok, _} <- Sharing.change(:sharing_enable, params, remote.advertised_routes) do
      :ok
    end
  end

  defp sharing_allowed(:sharing_disable, params, remote) do
    with {:ok, _} <- Sharing.change(:sharing_disable, params, remote.advertised_routes) do
      :ok
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
    observed = snapshot(state)

    enabled =
      cond do
        state.operation == "connect" ->
          true

        observed.available and
            observed.auth_state in ["authenticated", "authenticating", "needs_approval"] ->
          true

        observed.available and observed.auth_state in ["stopped", "needs_login"] ->
          false

        true ->
          state.enabled
      end

    Alarms.report(
      :remote_unavailable,
      state.name,
      if(observed.available, do: false, else: enabled)
    )

    Observations.put(path(state), :erlang.phash2(observed))
    %{state | enabled: enabled}
  end

  defp sources(state),
    do: [{Observations.table(), path(state)} | Observations.sources(state.adapter)]

  defp path(state), do: Observations.workflow("remote", state.id)
end

defmodule NervesGate.Remote do
  @moduledoc """
  Tailscale connection and device-name control.

  ## Commands

  `connect/2`, `configure/2` and `disconnect/0` return `:ok` when accepted,
  or `{:error, reason}`. Only one daemon operation runs at a time. Acceptance
  does not mean completion: read `status/0` for `:operation` and `:error`.
  Editors pass `expected:`, the hostname their draft started from; a changed
  hostname is rejected as stale before any daemon write.

  ## Queries and notifications

  `status/0` returns sanitized daemon observations. `login_url/0` is a private
  query; its result never enters status or notifications. Subscribe with
  `observe/0` before reading, then reread when properties change.

  The daemon retains
  identity and preferences across process restarts; user commands are not replayed.
  Once online with a DNS name, an owned worker configures HTTPS Serve on port 443
  to the gateway UI on port 4000. It runs once per observed DNS name, including
  startup and rename. A failed setup is not automatically retried; connect or save
  the same device name to retry. The daemon persists the listener configuration.

  `:remote_unavailable` reports daemon loss after a connect request or an active
  authentication/connection observation. An available daemon clears it, including
  while offline or awaiting approval. Stopped/unconfigured connections do not
  require a daemon for this alarm. Unknown startup observations preserve an old
  report; no connection intent is persisted here.
  """
  use GenServer
  alias NervesGate.{Alarms, Observations}
  alias NervesGate.Remote.{Policy, Sharing}

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Request connection or enrollment. Optional `auth_key:` is transient, never persisted."

  def connect(hostname, opts \\ []) do
    params = %{"hostname" => hostname}

    params =
      if Keyword.has_key?(opts, :auth_key),
        do: Map.put(params, "auth_key", opts[:auth_key]),
        else: params

    command(:connect, params, opts)
  end

  @doc "Request a hostname change without changing connection intent; preserves omitted preferences."

  def configure(hostname, opts \\ []), do: command(:configure, %{"hostname" => hostname}, opts)

  @doc "Request Tailscale down without logging out. May disconnect a caller using the VPN."

  def disconnect, do: command(:disconnect, %{}, [])

  @doc "Read daemon observations and the current operation/error. Never returns an enrollment URL."

  def status do
    case NervesGate.Error.protect(fn -> GenServer.call(__MODULE__, :status) end) do
      {:error, _} -> unavailable()
      status -> status
    end
  end

  @doc "Read the validated HTTPS enrollment URL, or nil. Do not log or broadcast it."
  def login_url do
    case NervesGate.Error.protect(fn -> GenServer.call(__MODULE__, :login_url) end) do
      {:error, _} -> {:error, %{code: "remote_unavailable", message: "Tailscale is unavailable."}}
      url -> {:ok, url}
    end
  end

  @doc "Subscribe the caller to property-change hints; read status afterward and on each notification."

  def observe, do: NervesGate.Error.protect(fn -> Observations.subscribe_runtime(__MODULE__) end)

  # Route mutations must hold Network's LAN worker. Called by Network, not clients.
  @doc false
  def sharing(operation, params),
    do:
      NervesGate.Error.protect(fn ->
        GenServer.call(__MODULE__, {:sharing, operation, params}, 45_000)
      end)

  @doc false
  defdelegate unavailable(), to: Policy

  defp command(operation, params, opts) do
    case NervesGate.Error.protect(fn ->
           GenServer.call(
             __MODULE__,
             {:command, operation, params, Keyword.get(opts, :expected, :any)}
           )
         end) do
      {:error, reason} -> {:error, NervesGate.Error.safe(reason)}
      result -> result
    end
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    Alarms.register(__MODULE__, [:remote_unavailable, :remote_offline, :remote_health])

    state = %{
      name: __MODULE__,
      enabled: nil,
      sharing:
        Map.get(NervesGate.Remote.Tailscaled.snapshot(), :sharing, Policy.unavailable().sharing),
      waiting: nil,
      route: nil,
      id: inspect(__MODULE__),
      worker: nil,
      operation: nil,
      error: nil,
      serve_dns_name: nil,
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
    {:reply, NervesGate.Remote.Tailscaled.login_url() |> Policy.login_url(), state}
  end

  def handle_call({:command, operation, params, expected}, _, state) do
    observed = snapshot(state)

    with :ok <- Policy.available(observed),
         :ok <- Policy.expected(observed, expected),
         {:ok, params} <- Policy.validate(operation, params) do
      state =
        if operation in [:connect, :configure] do
          # Retry Serve for an unchanged name, but a rename waits for new DNS.
          attempted =
            if params.hostname == observed.hostname do
              nil
            else
              observed.dns_name
            end

          %{state | serve_dns_name: attempted}
        else
          state
        end

      {:reply, :ok, state |> start_operation(operation, params) |> publish()}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:sharing, operation, params}, from, state) do
    with :ok <- Policy.available(snapshot(state)),
         :ok <- sharing_allowed(operation, params, snapshot(state)) do
      state =
        %{state | waiting: from, route: params[:route]} |> start_operation(operation, params)

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

  defp sharing_allowed(_, _, _),
    do:
      {:error,
       %{
         code: "sharing_unknown",
         message:
           "Sharing state is unknown. Turn sharing off and wait for confirmation before changing LAN settings."
       }}

  @impl true
  def handle_info({ref, result}, %{worker: {%Task{ref: ref}, _}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, complete(state, result)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{worker: {%Task{ref: ref}, _}} = state),
    do:
      {:noreply,
       complete(
         state,
         {:error,
          %{
            code: "outcome_unknown",
            message: "The command reply was lost. Read the current state before retrying."
          }}
       )}

  def handle_info({:timeout, ref}, %{worker: {%Task{ref: ref} = task, _}} = state) do
    Task.shutdown(task, :brutal_kill)
    {:noreply, complete(state, {:error, :timeout})}
  end

  def handle_info(:poll, state) do
    Observations.subscribe(sources(state))
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, publish(state)}
  end

  def handle_info(%PropertyTable.Event{}, state) do
    {:noreply, publish(state)}
  end

  def handle_info({Tailscaled, _, _, _, _}, state) do
    {:noreply, publish(state)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{worker: {task, _}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  # A failed command's mailbox message can contain an enrollment key.
  @impl true
  def format_status(status), do: Map.put(status, :message, :redacted)

  defp start_operation(state, operation, params) do
    task = Task.async(fn -> execute(operation, params) end)
    timer = Process.send_after(self(), {:timeout, task.ref}, state.timeout)
    %{state | worker: {task, timer}, operation: Atom.to_string(operation), error: nil}
  end

  # Do not let task crash reports include credential-bearing arguments or errors.
  defp execute(:connect, %{auth_key: _} = params) do
    NervesGate.Remote.Tailscaled.execute(:connect, params)
  catch
    _, _ ->
      {:error,
       %{
         code: "outcome_unknown",
         message: "The command reply was lost. Read the current state before retrying."
       }}
  end

  defp execute(operation, params), do: NervesGate.Remote.Tailscaled.execute(operation, params)

  defp maybe_serve(state) do
    case Policy.serve_dns_name(snapshot(state), state.serve_dns_name) do
      nil ->
        state

      dns_name ->
        %{state | serve_dns_name: dns_name}
        |> start_operation(:serve, %{dns_name: dns_name})
    end
  end

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
        GenServer.reply(
          state.waiting,
          {:error,
           %{
             code: "sharing_unknown",
             message:
               "Sharing state is unknown. Turn sharing off and wait for confirmation before changing LAN settings."
           }}
        )

        uncertain = Enum.uniq(state.sharing.uncertain ++ List.wrap(state.route))
        %{state | sharing: %{ready: state.route != nil, uncertain: uncertain}}
    end
  end

  defp snapshot(state) do
    NervesGate.Remote.Tailscaled.snapshot()
    |> Policy.sanitize()
    |> Map.merge(%{operation: state.operation, error: state.error, sharing: state.sharing})
  end

  defp publish(state) do
    state = maybe_serve(state)
    observed = snapshot(state)
    NervesGate.Distribution.ensure_started(observed)

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

    Alarms.report(:remote_health, state.name, remote_health(observed, enabled))
    Alarms.report(:remote_offline, state.name, remote_offline(observed, enabled))

    Observations.put(path(state), :erlang.phash2(observed))
    %{state | enabled: enabled}
  end

  defp remote_health(_, false), do: false
  defp remote_health(%{available: true, health: health}, true), do: health != []
  defp remote_health(_, _), do: nil

  defp remote_offline(_, false), do: false

  defp remote_offline(%{available: true, auth_state: "authenticated", state: state}, true)
       when state in ["online", "offline"],
       do: state == "offline"

  defp remote_offline(%{available: true, auth_state: auth}, true)
       when auth in ["authenticating", "needs_approval"],
       do: false

  defp remote_offline(_, _), do: nil

  defp sources(state),
    do: [{Observations.table(), path(state)} | NervesGate.Remote.Tailscaled.observations()]

  defp path(state), do: Observations.workflow("remote", state.id)
end

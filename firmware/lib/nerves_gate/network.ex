defmodule NervesGate.Network do
  @moduledoc """
  Ethernet and Internet uplink configuration with protected trials and rollback.

  ## Commands

  `propose/2` applies settings temporarily and returns `{:ok, trial_id}`.
  `confirm/1` saves that trial; `cancel/1` restores saved settings. Both return
  `:ok` after completion. Rejected or failed commands return `{:error, reason}`.
  Manual trials expire after 60 seconds. First setup through verified USB may
  auto-save within 15 seconds. A caller timeout does not cancel admitted work.

  ## Queries and notifications

  `validate/1`, `ready?/2` and `conflicts/2` are pure checks. `status/0` reads the
  current trial, settings and interfaces. Subscribe with `observe/0` before
  reading; notifications are hints to read again, not complete status maps.

  VintageNet owns saved settings.
  Failed restoration sets `:network_restore_failed`; successful restoration clears it.
  """
  use GenServer
  alias NervesGate.{Alarms, Cellular, Config, Observations, Remote}
  alias NervesGate.Network.{Access, Local, Policy}
  alias NervesGate.Remote.Sharing

  @doc false
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Validate and normalize string-keyed settings without reading or changing hardware."
  @spec validate(map()) :: {:ok, map()} | {:error, NervesGate.Error.t()}
  def validate(network) do
    case Config.validate_network(network) do
      {:error, message} -> {:error, NervesGate.Error.new("invalid_parameters", message)}
      result -> result
    end
  end

  @doc """
  Apply a temporary trial and return its ID after application.

  Immediately-ready first USB setup waits for auto-save before replying. If still
  settling, it returns a pending trial. `access` must come from trusted server
  observations of both socket endpoints, never user input; omit it for manual setup.
  Supply `expected` to reject a draft if the saved network settings have changed.
  """
  @spec propose(map(), keyword()) :: {:ok, String.t()} | {:error, NervesGate.Error.t()}
  def propose(network, opts \\ []) do
    with {:ok, network} <- validate(network) do
      call({:propose, network, opts[:access], Keyword.get(opts, :expected, :any)}, 15_000)
    end
  end

  @doc "Persist the matching, unexpired trial after checking readiness."
  def confirm(id), do: trial(:confirm, id)

  @doc "Restore saved settings for the matching trial."
  def cancel(id), do: trial(:cancel, id)

  @doc "Read independent domain state, or nil while its owner is unavailable."
  def status do
    case call(:status) do
      {:error, _} -> nil
      status -> Map.update!(status, :error, &error/1)
    end
  end

  @doc "Claim one enabled, isolated Ethernet interface for the actual calling process. Addressing is transient."
  def claim_local(interface, address, prefix),
    do: call({:claim_local, interface, address, prefix}, 70_000)

  @doc "Advertise only this caller's local claim. No route is advertised by claiming alone."
  def advertise_local(ref), do: call({:advertise_local, ref}, 70_000)

  @doc "Withdraw the owned route before removing the claim's temporary address."
  def release_local(ref), do: call({:release_local, ref}, 70_000)

  @doc "Private caller-owned lease observation. Never put its handle in public projections."
  def local_status, do: call({:local_status, Remote.status()})

  @doc "Explicitly retry cleanup of an orphaned claim after inspecting an incomplete outcome. Never re-advertises."
  def recover_local, do: call(:recover_local, 70_000)

  @doc "Subscribe the calling process before reading status."
  def observe, do: NervesGate.Error.protect(fn -> Observations.subscribe_runtime(__MODULE__) end)

  defp trial(operation, id) when is_binary(id), do: call({operation, id}, 15_000)

  defp trial(_, _),
    do: {:error, NervesGate.Error.new("invalid_parameters", "Supply a trial ID string.")}

  defp call(request, timeout \\ 5_000) do
    case NervesGate.Error.protect(fn -> GenServer.call(__MODULE__, request, timeout) end) do
      {:error, reason} -> {:error, error(reason)}
      result -> result
    end
  end

  @doc "Check that observed topology/settings match the proposal, without subnet conflicts."
  @spec ready?(map() | nil, map()) :: boolean()
  defdelegate ready?(observed, network), to: Policy

  @doc "List observed subnet conflicts for these settings without performing I/O."
  @spec conflicts(map() | nil, map()) :: list()
  defdelegate conflicts(observed, network), to: Policy

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    Alarms.register(__MODULE__, [
      :network_restore_failed,
      :internet_unavailable,
      :internet_backup,
      :cellular_unavailable
    ])

    effect_ms = Keyword.get(opts, :effect_ms, 10_000)
    local = Local.load()
    {config, error} = load(effect_ms, local)

    state = %{
      name: __MODULE__,
      id: inspect(__MODULE__),
      config: config,
      error: error,
      trial: nil,
      deadline: nil,
      timer: nil,
      worker: nil,
      proposal_reply: nil,
      recovering: match?({:restore, _}, error),
      observed: nil,
      cellular: Cellular.cached(),
      cellular_controller: nil,
      trial_ms: Keyword.get(opts, :trial_ms, 60_000),
      poll_ms: Keyword.get(opts, :poll_ms, 1000),
      effect_ms: effect_ms,
      observation_timer: nil,
      local: local
    }

    Observations.subscribe(sources(state))
    send(self(), :poll)
    {:ok, state |> refresh() |> publish()}
  end

  @impl true
  def handle_call(:status, _, state) do
    state = refresh(state)
    {:reply, Map.put(public(state), :sharing_admission, lan_change(state)), state}
  end

  def handle_call(:observations, _, state) do
    {:reply, sources(state), state}
  end

  def handle_call({:claim_local, interface, address, prefix}, {pid, _} = from, state) do
    state = refresh(state)

    with :ok <- Local.idle(state.local),
         {:ok, scope} <- Local.candidate(public(state), interface, address, prefix) do
      ref = make_ref()
      local = %{Local.lease(scope, pid, :configuring) | ref: ref, monitor: Process.monitor(pid)}

      {:noreply,
       local_work(%{state | local: local}, :claim, from, fn -> Local.reserve(scope) end)
       |> publish()}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({operation, ref}, {pid, _} = from, state)
      when operation in [:advertise_local, :release_local] do
    state = refresh(state)

    with :ok <- Local.owned(state.local, pid, ref),
         :ok <- Policy.available(Map.put(public(state), :local, nil)),
         :ok <- Local.action_allowed(operation, state.local, public(state)) do
      scope = state.local.scope

      {action, fun} =
        if operation == :advertise_local,
          do: {:advertise, fn -> Local.advertise(scope) end},
          else: {:release, fn -> Local.cleanup(scope) end}

      {:noreply, local_work(state, action, from, fun) |> publish()}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:local_status, remote}, {pid, _}, state) do
    state = refresh(state)
    {:reply, {:ok, Local.observation(state.local, pid, public(state), remote)}, state}
  end

  def handle_call(:recover_local, from, %{local: %{owner: nil, scope: scope}} = state)
      when not is_nil(scope) do
    if state.worker == nil and state.trial == nil,
      do:
        {:noreply, local_work(state, :release, from, fn -> Local.cleanup(scope) end) |> publish()},
      else:
        {:reply,
         {:error,
          NervesGate.Error.new("operation_in_progress", "Wait for the current network operation.")},
         state}
  end

  def handle_call(:recover_local, _, state),
    do:
      {:reply,
       {:error,
        NervesGate.Error.new(
          "local_cleanup_required",
          "No recoverable orphaned claim is available. Inspect its owner and persistent journal."
        )}, state}

  def handle_call({:cellular, :unlock, params, :tracked}, from, state) do
    case handle_call({:cellular, :unlock, params}, from, state) do
      {:reply, :ok, state} -> {:reply, {:ok, state.worker.cellular_id}, state}
      reply -> reply
    end
  end

  def handle_call({:cellular, operation, params}, _, state) do
    state = refresh(state)

    with :ok <- Cellular.parameters(operation, params),
         :ok <- Cellular.available(public(state), operation) do
      {:reply, :ok, start_cellular(state, operation, params) |> publish()}
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call({:propose, network, access, expected}, from, state) do
    state |> refresh() |> propose(network, access, expected, from) |> respond()
  end

  def handle_call({operation, id}, from, state) when operation in [:confirm, :cancel] do
    execute_trial(operation, id, from, refresh(state)) |> respond()
  end

  defp respond({:pending, state}), do: {:noreply, publish(state)}
  defp respond({result, state}), do: {:reply, result, publish(state)}

  defp propose(state, input, access, expected, from) do
    with :ok <- Policy.available(public(state)),
         :ok <- check_expected(state, expected),
         {:ok, network} <- validate(input),
         :ok <- Policy.supported(state.observed, network, state.config["network"]),
         :ok <- lan_change(state) do
      auto = not state.config["setup_completed"] and Access.usb?(state.observed, access)
      timeout = if auto, do: 15_000, else: state.trial_ms

      trial = %{
        id: Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false),
        network: network,
        auto_save: auto,
        expires_at: System.system_time(:millisecond) + timeout
      }

      state = %{
        state
        | trial: trial,
          deadline: now() + timeout,
          error: nil,
          timer: Process.send_after(self(), {:expire, trial.id}, timeout),
          proposal_reply: {from, {:ok, trial.id}}
      }

      {:pending,
       work(state, :apply, nil, fn -> NervesGate.Network.Vintage.apply_config(network) end)}
    else
      error -> {error, state}
    end
  end

  defp check_expected(_state, :any), do: :ok

  defp check_expected(state, expected) do
    if state.config["network"] == expected,
      do: :ok,
      else:
        {:error,
         %{
           code: "stale_network",
           message:
             "Network settings changed in another session. Reload saved settings before editing."
         }}
  end

  defp execute_trial(_, _, _, %{worker: worker} = state) when not is_nil(worker),
    do:
      {{:error,
        %{
          code: "recovery_in_progress",
          message: "Wait for saved settings to be restored before trying again."
        }}, state}

  defp execute_trial(operation, id, from, state) do
    case Policy.matching(public(state), id) do
      :ok -> execute(operation, from, state)
      error -> {error, state}
    end
  end

  defp execute(:cancel, from, state),
    do: {:pending, restore(state, :cancelled, from, :ok)}

  defp execute(:confirm, from, state) do
    cond do
      expired?(state) ->
        {:pending, expire(state, from)}

      not ready?(state) ->
        {{:error,
          %{
            code: "not_connected",
            message:
              "Port settings are not ready to save. Check the connection status and any address conflicts below."
          }}, state}

      true ->
        {:pending, save(state, from)}
    end
  end

  defp auto_save(%{trial: %{auto_save: true}, worker: nil} = state) do
    cond do
      expired?(state) ->
        expire(state, nil)

      ready?(state) ->
        save(state, nil)

      conflicted?(state) ->
        restore(
          state,
          :conflicting_networks,
          nil,
          {:error,
           %{
             code: "conflicting_networks",
             message:
               "Network addresses overlap. Previous settings have been restored. Choose different Ethernet, cellular, equipment and USB subnets."
           }}
        )

      true ->
        finish_proposal(state)
    end
  end

  defp auto_save(state), do: state

  @impl true
  def handle_info({ref, result}, %{worker: %{task: %{ref: ref}} = worker} = state) do
    Process.demonitor(ref, [:flush])
    Process.cancel_timer(worker.timer)
    {:noreply, complete(%{state | worker: nil}, worker, result) |> publish()}
  end

  def handle_info(
        {:DOWN, ref, :process, _, reason},
        %{worker: %{task: %{ref: ref}} = worker} = state
      ) do
    Process.cancel_timer(worker.timer)

    {:noreply,
     complete(%{state | worker: nil}, worker, {:error, {:worker_failed, reason}}) |> publish()}
  end

  def handle_info({:work_timeout, ref}, %{worker: %{task: %{ref: ref}}} = state),
    do: {:noreply, interrupt(state, :operation_timeout) |> publish()}

  def handle_info({:expire, id}, %{trial: %{id: id}} = state),
    do: {:noreply, expire(state, nil) |> publish()}

  def handle_info({:DOWN, ref, :process, _, _}, %{local: %{monitor: ref} = local} = state)
      when is_reference(ref) do
    local = %{local | owner: nil, monitor: nil, phase: :cleanup_pending}
    {:noreply, %{state | local: local} |> publish()}
  end

  def handle_info(:poll, state) do
    Observations.subscribe(sources(state))
    Process.send_after(self(), :poll, state.poll_ms)
    {:noreply, reconcile(state)}
  end

  def handle_info(:observations_changed, state),
    do: {:noreply, reconcile(%{state | observation_timer: nil})}

  def handle_info(%PropertyTable.Event{}, state), do: {:noreply, observe_later(state)}
  def handle_info({VintageNet, _, _, _, _}, state), do: {:noreply, observe_later(state)}
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, %{worker: %{task: task}}), do: Task.shutdown(task, :brutal_kill)
  def terminate(_, _), do: :ok

  defp observe_later(%{observation_timer: nil} = state),
    do: %{state | observation_timer: Process.send_after(self(), :observations_changed, 20)}

  defp observe_later(state), do: state

  defp reconcile(state) do
    state = refresh(state)

    state =
      cond do
        expired?(state) -> expire(state, nil)
        state.recovering and state.worker == nil -> restore(state, state.error, nil, :ok)
        true -> state |> auto_save() |> reconcile_sharing() |> reconcile_local()
      end

    state |> refresh_cellular_if_due() |> publish()
  end

  defp start_cellular(state, operation, params) do
    state = %{state | cellular: %{state.cellular | operation: operation, error: nil}}
    state = work(state, :cellular, nil, fn -> Cellular.perform(operation, params) end)

    %{
      state
      | worker:
          Map.put(state.worker, :cellular_id, System.unique_integer([:positive, :monotonic]))
    }
  end

  defp refresh_cellular_if_due(state) do
    case Cellular.next(public(state), state.cellular_controller) do
      nil ->
        state

      {controller, operation, fun} ->
        state = %{
          state
          | cellular_controller: controller,
            cellular: %{state.cellular | operation: operation, error: nil}
        }

        work(state, :cellular, nil, fun)
    end
  end

  defp work(state, operation, from, fun) do
    task = Task.async(fun)

    timeout =
      case operation do
        :local -> 65_000
        :sharing -> 65_000
        :cellular -> 45_000
        _ -> state.effect_ms
      end

    timer = Process.send_after(self(), {:work_timeout, task.ref}, timeout)
    %{state | worker: %{task: task, timer: timer, operation: operation, from: from}}
  end

  defp reconcile_local(
         %{
           local: %{phase: :cleanup_pending, scope: scope},
           worker: nil,
           trial: nil,
           recovering: false
         } = state
       ) do
    local_work(state, :release, nil, fn -> Local.cleanup_if_ready(scope) end)
  end

  defp reconcile_local(state), do: state

  defp local_work(state, action, from, fun) do
    state =
      %{state | local: %{state.local | phase: action, error: nil}} |> work(:local, from, fun)

    %{state | worker: Map.put(state.worker, :local_action, action)}
  end

  defp complete(state, %{operation: :local, local_action: action, from: from}, result) do
    {local, response} = Local.complete(state.local, action, result)

    if local == nil and state.local.monitor do
      Process.demonitor(state.local.monitor, [:flush])
    end

    reply(from, response)
    %{state | local: local}
  end

  defp complete(state, %{operation: :cellular} = worker, result) do
    cellular = Cellular.complete(result, state.cellular, Map.get(worker, :cellular_id))
    # Retry only the startup read that could not reach the controller. Once any
    # SIM/radio write was attempted, initialization is never automatically replayed.
    controller =
      case {state.cellular.operation, cellular.error} do
        {:initialize, %{code: "cellular_controller_starting"}} -> nil
        _ -> state.cellular_controller
      end

    %{state | cellular: cellular, cellular_controller: controller}
  end

  defp complete(state, %{operation: :sharing, from: from}, result) do
    reply(
      from,
      case result do
        {:ok, _routes} -> :ok
        {:error, reason} -> {:error, error(reason)}
      end
    )

    state
  end

  defp complete(state, %{operation: :apply}, :ok) do
    state = refresh(%{state | cellular: %{Cellular.cached() | result: state.cellular.result}})

    cond do
      expired?(state) -> expire(state, nil)
      state.trial.auto_save -> auto_save(state)
      true -> finish_proposal(state)
    end
  end

  defp complete(state, %{operation: :save, from: from}, :ok) do
    state = %{state | config: Config.from_network(state.trial.network), error: nil}
    reply(from, :ok)
    state |> clear_trial() |> finish_proposal()
  end

  defp complete(state, %{operation: :restore, from: {from, result}}, outcome) do
    error =
      case outcome do
        :ok -> nil
        {:error, reason} -> {:restore, reason}
      end

    reply(from, if(error, do: {:error, error}, else: result))
    previous = if match?({:restore, _}, state.error), do: nil, else: state.error

    %{state | recovering: error != nil, error: error || previous, cellular: Cellular.cached()}
    |> finish_proposal()
    |> refresh()
  end

  defp complete(state, %{operation: operation, from: from}, {:error, reason}) do
    reason = if operation == :save, do: {:save, reason}, else: {:apply, reason}
    restore(state, reason, from, {:error, reason})
  end

  defp save(state, from),
    do: work(state, :save, from, fn -> NervesGate.Network.Vintage.save(state.trial.network) end)

  defp restore(state, reason, from, result) do
    state =
      case state.proposal_reply do
        {caller, _} -> %{state | proposal_reply: {caller, {:error, reason}}}
        nil -> state
      end
      |> clear_trial()

    state = %{state | recovering: true, error: if(reason == :cancelled, do: nil, else: reason)}

    work(state, :restore, {from, result}, fn ->
      NervesGate.Network.Vintage.restore(state.config["network"])
    end)
  end

  defp interrupt(%{worker: %{operation: operation} = worker} = state, reason)
       when operation in [:sharing, :cellular, :local] do
    {state, _} = stop_work(state)
    complete(state, worker, {:error, reason})
  end

  defp interrupt(state, reason) do
    reason =
      if match?(%{operation: :restore}, state.worker) do
        {:restore, reason}
      else
        reason
      end

    {state, from} = stop_work(state)
    restore(state, reason, from, {:error, reason})
  end

  defp expire(state, from) do
    {state, waiting} = stop_work(state)

    restore(
      state,
      :expired,
      from || waiting,
      {:error,
       %{code: "expired", message: "The trial expired. Previous settings are being restored."}}
    )
  end

  defp stop_work(%{worker: nil} = state), do: {state, nil}

  defp stop_work(%{worker: worker} = state) do
    Task.shutdown(worker.task, :brutal_kill)
    Process.cancel_timer(worker.timer)
    from = if worker.operation == :restore, do: elem(worker.from, 0), else: worker.from
    {%{state | worker: nil}, from}
  end

  defp clear_trial(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | trial: nil, deadline: nil, timer: nil}
  end

  defp finish_proposal(%{proposal_reply: nil} = state), do: state

  defp finish_proposal(%{proposal_reply: {from, result}} = state) do
    reply(from, result)
    %{state | proposal_reply: nil}
  end

  defp reply(nil, _), do: :ok
  defp reply(from, result), do: GenServer.reply(from, result)

  defp refresh(state) do
    case NervesGate.Network.Vintage.snapshot() do
      nil ->
        %{state | observed: nil, error: state.error || {:discovery, :unavailable}}

      observed ->
        error = if match?({:discovery, _}, state.error), do: nil, else: state.error

        changed =
          get_in(state.observed || %{}, [:cellular, :present]) !=
            get_in(observed, [:cellular, :present])

        cellular = if changed, do: Cellular.reset(state.cellular), else: state.cellular

        %{state | observed: observed, error: error, cellular: cellular}
    end
  end

  defp public(state) do
    %{
      config: state.config,
      trial: state.trial,
      observed: state.observed,
      cellular: state.cellular,
      error: error(state.error),
      recovering: state.recovering,
      ready: ready?(state),
      phase: phase(state),
      local: Local.public(state.local)
    }
  end

  # Recovery uses the monotonic deadline; trial.expires_at is only for display.
  defp expired?(%{trial: nil}), do: false
  defp expired?(state), do: now() >= state.deadline

  defp ready?(%{trial: nil}), do: false
  defp ready?(state), do: Policy.ready?(state.observed, state.trial.network)
  defp conflicted?(state), do: Policy.conflicts(state.observed, state.trial.network) != []
  defp phase(%{worker: %{operation: operation}}), do: operation
  defp phase(%{recovering: true}), do: :restore
  defp phase(%{trial: nil}), do: :idle
  defp phase(_), do: :pending

  defp sources(state),
    do: [
      {Observations.table(), Observations.workflow("network", state.id)}
      | NervesGate.Network.Vintage.observations()
    ]

  defp publish(state) do
    Observations.put(
      Observations.workflow("network", state.id),
      Map.delete(public(state), :observed)
    )

    Alarms.report(:network_restore_failed, state.name, match?({:restore, _}, state.error))
    Alarms.report(:internet_unavailable, state.name, internet_fault(state))
    internet = Observations.Network.internet(public(state))

    backup =
      if internet.mode == "backup" and internet.connection == :unknown,
        do: nil,
        else: internet.backup

    Alarms.report(:internet_backup, state.name, backup)
    Alarms.report(:cellular_unavailable, state.name, cellular_fault(internet.cellular))

    state
  end

  defp internet_fault(state) do
    case Observations.Network.internet(public(state)) do
      %{expected: false} when not is_nil(state.config) -> false
      %{connection: :internet} -> false
      %{expected: true, connection: connection} when connection in [:lan, :disconnected] -> true
      _ -> nil
    end
  end

  defp cellular_fault(connection) when connection in [:internet, :disabled], do: false
  defp cellular_fault(connection) when connection in [:lan, :disconnected], do: true
  defp cellular_fault(_), do: nil

  defp load(timeout, local) do
    case bounded(fn -> NervesGate.Network.Vintage.load() end, timeout) do
      # Do not flush a surviving claimed address on a Network restart before
      # its advertised route has been withdrawn. Boot-time VintageNet restore
      # is independent; the journal still blocks all new access until cleanup.
      {:ok, config} -> {config, if(local == nil, do: restore_loaded(config, timeout))}
      {:error, reason} -> {nil, {:load, reason}}
    end
  end

  defp restore_loaded(config, timeout) do
    case bounded(fn -> NervesGate.Network.Vintage.restore(config["network"]) end, timeout) do
      :ok -> nil
      {:error, reason} -> {:restore, reason}
    end
  end

  defp bounded(fun, timeout) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, {:worker_failed, reason}}

      nil ->
        {:error, %{code: "operation_timeout", message: "The operation exceeded its time limit."}}
    end
  end

  defp lan_change(_state), do: Remote.status() |> Sharing.lan_change()

  defp share(state, operation, params, from) do
    work(state, :sharing, from, fn -> Remote.sharing(operation, params) end)
  end

  defp reconcile_sharing(%{worker: nil, trial: nil, recovering: false} = state) do
    maybe_sync(state, Remote.status())
  end

  defp reconcile_sharing(state), do: state

  # One read-only Controller barrier after Remote starts. Never replay a route write.
  defp maybe_sync(state, %{
         available: true,
         operation: nil,
         sharing: %{ready: false, uncertain: []}
       }),
       do: share(state, :sharing_sync, %{}, nil)

  defp maybe_sync(state, _), do: state

  defp error(nil), do: nil

  defp error({:apply, _}),
    do: %{code: "apply_failed", message: "Could not apply settings. Restoring saved settings."}

  defp error({:save, _}),
    do: %{code: "save_failed", message: "Could not save settings. Restoring saved settings."}

  defp error({:restore, _}),
    do: %{
      code: "recovery_in_progress",
      message: "Wait for saved settings to be restored before trying again."
    }

  defp error({:load, _}),
    do: %{
      code: "invalid_saved_config",
      message:
        "Saved settings could not be used. Legacy equipment/joined networks require explicitly authorized migration; use recovery SSH or serial. No saved settings were rewritten."
    }

  defp error({:discovery, _}),
    do: %{code: "discovery_failed", message: "Connection status is unavailable."}

  defp error(:expired),
    do: %{code: "expired", message: "The trial expired. Previous settings are being restored."}

  defp error(:conflicting_networks),
    do: %{
      code: "conflicting_networks",
      message:
        "Network addresses overlap. Previous settings have been restored. Choose different Ethernet, cellular, equipment and USB subnets."
    }

  defp error(:operation_timeout),
    do: %{
      code: "operation_timeout",
      message: "The operation exceeded its time limit. Read the current state before retrying."
    }

  defp error({:worker_failed, _}),
    do: %{
      code: "outcome_unknown",
      message: "The command reply was lost. Read the current state before retrying."
    }

  defp error(reason), do: NervesGate.Error.safe(reason)

  defp now, do: System.monotonic_time(:millisecond)
end

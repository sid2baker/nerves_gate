defmodule NervesGate.IO do
  @moduledoc """
  Observed inputs, exclusive output Authority and runtime-only Desires.

  Plugins register inputs and publish Readings using local IDs in their managed
  activation. Outputs are bound to a plugin-supervised handler, normally the SDK's
  `NervesGateSDK.Output` runtime. Readers and writers use full IDs. Subscribe
  before reading; monitor the returned controller PID and subscribe afresh after
  its loss. A snapshot read consumes this caller's outstanding hint. Changes
  coalesce until that read, never silently disappear.

  Every claim starts a new claim epoch. Only the bound handler reads the Desire with
  its epoch and reports Apply outcomes for it; reports for an ended epoch or a
  superseded Desire are rejected. Output Status interprets the Apply outcome and
  declared evidence (`NervesGate.IO.OutputStatus`); it is never authority.

  Plugins own all physical reconciliation, retries and release behaviour. A
  successful `set_output/2` stores a Desire only. Release, process loss and restart
  cause no implicit device operation. This domain provides no safety guarantee.

  Unsupported or unreadable saved definitions are kept untouched; the controller
  then stays up with I/O disabled and refuses every endpoint operation.
  """
  use GenServer
  alias NervesGate.IO.{Catalog, Definition, OutputStatus}
  alias NervesGate.Plugins.Owner
  alias NervesGateSDK.IO.{InputDefinition, OutputDefinition, Reading}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Register a persisted input definition in the actual calling plugin's namespace."
  def register_input(%InputDefinition{} = definition),
    do: GenServer.call(__MODULE__, {:register_input, definition})

  def register_input(_), do: {:error, :invalid_definition}

  @doc "Bind a repeatable output to a supervised handler in the calling plugin's activation."
  def register_output(%OutputDefinition{} = definition, handler) when is_pid(handler),
    do: GenServer.call(__MODULE__, {:register_output, definition, handler})

  def register_output(_, _), do: {:error, :invalid_definition}

  @doc "Replace the caller's latest Reading, including invalid/unknown samples."
  def publish(local_id, value, quality \\ :good),
    do: GenServer.call(__MODULE__, {:publish, local_id, value, quality})

  @doc """
  Read the bound handler's current Desire and claim epoch. A nil Desire means no
  active target, never a default; a nil epoch means unclaimed.
  """
  def read_desired(local_id) do
    consume_hint(:nerves_gate_output_changed, local_id)
    GenServer.call(__MODULE__, {:read_desired, local_id})
  end

  @doc "Record the bound handler's Apply outcome for `value` in claim `epoch`."
  def report_applied(local_id, epoch, value, outcome),
    do: GenServer.call(__MODULE__, {:report_applied, local_id, epoch, value, outcome})

  @doc "Read persisted definitions, independent of live availability."
  def definitions, do: GenServer.call(__MODULE__, :definitions)

  @doc "Read the latest Reading, quality and monotonic freshness. Consumes this caller's input hint."
  def input(full_id) do
    consume_hint(:nerves_gate_input_changed, full_id)
    GenServer.call(__MODULE__, {:input, full_id})
  end

  @doc """
  Read Desire and Status, never a guarantee of device state. `owned?` is relative to
  the actual caller; other writers stay private.
  """
  def output(full_id), do: GenServer.call(__MODULE__, {:output, full_id})

  @doc """
  Read every persisted endpoint's current snapshot, sorted by full ID, for display.
  Consumes no caller hints. Output `owned?` is relative to the actual caller.
  """
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  @doc "Subscribe the actual caller to an input. Returns the controller PID to monitor."
  def subscribe(full_id), do: GenServer.call(__MODULE__, {:subscribe, full_id})

  def unsubscribe(full_id) do
    result = GenServer.call(__MODULE__, {:unsubscribe, full_id})
    consume_hint(:nerves_gate_input_changed, full_id)
    result
  end

  @doc "Exclusively claim an available output for the actual calling PID, without setting a Desire."
  def claim_output(full_id), do: GenServer.call(__MODULE__, {:claim_output, full_id})

  @doc "Set the caller-owned Desire. Success says nothing about physical device state."
  def set_output(full_id, value), do: GenServer.call(__MODULE__, {:set_output, full_id, value})

  @doc "Clear this caller's Desire and Authority. The plugin's release behaviour applies."
  def release_output(full_id), do: GenServer.call(__MODULE__, {:release_output, full_id})

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, "/data/nerves_gate/io.term")

    {definitions, error} =
      case Catalog.load(path) do
        {:ok, definitions} -> {definitions, nil}
        {:error, _} -> {%{}, :io_catalog_unavailable}
      end

    Process.send_after(self(), :sweep, 1_000)

    {:ok,
     %{
       path: path,
       catalog_error: error,
       definitions: definitions,
       bindings: %{},
       latest: %{},
       desires: %{},
       claims: %{},
       applied: %{},
       subscribers: %{},
       monitors: %{},
       storage_error: nil,
       clock: subscribe_clock()
     }}
  end

  @impl true
  def handle_call(_, _, %{catalog_error: error} = state) when error != nil,
    do: {:reply, {:error, error}, state}

  def handle_call({:register_input, definition}, {pid, _}, state),
    do: register(definition, pid, nil, sweep(state))

  def handle_call({:register_output, definition, handler}, {pid, _}, state),
    do: register(definition, pid, handler, sweep(state))

  def handle_call(:definitions, _, state), do: {:reply, state.definitions, sweep(state)}

  def handle_call({:publish, local_id, value, quality}, {pid, _}, state) do
    state = sweep(state)

    with {:ok, id, binding} <- caller_binding(state, pid, local_id),
         %InputDefinition{} = definition <- state.definitions[id],
         true <- binding.pid == pid,
         true <- Definition.reading?(definition, value, quality) do
      reading = %Reading{
        input_id: id,
        value: value,
        quality: quality,
        received_at_ms: System.monotonic_time(:millisecond),
        received_at_utc: utc(state.clock)
      }

      state = put_in(state.latest[id], reading) |> notify_input(id)
      {:reply, {:ok, reading}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :invalid_publication}, state}
    end
  end

  def handle_call({:read_desired, local_id}, {pid, _}, state) do
    state = sweep(state)

    case caller_binding(state, pid, local_id) do
      {:ok, id, %{handler: ^pid}} ->
        desire = %{desired: state.desires[id], epoch: epoch(state, id)}
        {:reply, {:ok, desire}, put_in(state.bindings[id].dirty?, false)}

      {:error, _} = error ->
        {:reply, error, state}

      _ ->
        {:reply, {:error, :not_output_handler}, state}
    end
  end

  def handle_call({:report_applied, local_id, epoch, value, outcome}, {pid, _}, state) do
    state = sweep(state)

    with {:ok, id, %{handler: ^pid}} <- caller_binding(state, pid, local_id),
         true <- outcome?(outcome) || {:error, :invalid_outcome},
         true <-
           (epoch != nil and epoch == epoch(state, id) and value == state.desires[id]) ||
             {:error, :stale_report} do
      applied = %{epoch: epoch, value: value, outcome: outcome}
      {:reply, :ok, put_in(state.applied[id], applied)}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :not_output_handler}, state}
    end
  end

  def handle_call({:input, id}, {pid, _}, state) do
    state = sweep(state)
    {:reply, input_snapshot(state, id), clean_input(state, pid, id)}
  end

  def handle_call({:output, id}, {pid, _}, state) do
    state = sweep(state)
    {:reply, output_snapshot(state, id, pid, System.monotonic_time(:millisecond)), state}
  end

  def handle_call(:snapshot, {pid, _}, state) do
    state = sweep(state)
    ids = state.definitions |> Map.keys() |> Enum.sort()
    now = System.monotonic_time(:millisecond)

    {:reply,
     %{
       inputs: for(id <- ids, {:ok, input} <- [input_snapshot(state, id)], do: input),
       outputs:
         for(id <- ids, {:ok, output} <- [output_snapshot(state, id, pid, now)], do: output)
     }, state}
  end

  def handle_call({:subscribe, id}, {pid, _}, state) do
    state = sweep(state)

    if match?(%InputDefinition{}, state.definitions[id]) and alive?(pid) do
      subscriptions = Map.put_new(Map.get(state.subscribers, pid, %{}), id, false)
      state = put_in(state.subscribers[pid], subscriptions) |> watch(pid)
      {:reply, {:ok, self()}, state}
    else
      {:reply, {:error, :unknown_input}, state}
    end
  end

  def handle_call({:unsubscribe, id}, {pid, _}, state) do
    subscribers = Map.update(state.subscribers, pid, %{}, &Map.delete(&1, id))
    {:reply, :ok, sweep(%{state | subscribers: subscribers})}
  end

  def handle_call({:claim_output, id}, {pid, _}, state) do
    state = sweep(state)

    with :ok <- writable(state, id),
         true <- alive?(pid),
         claim = state.claims[id],
         true <- claim == nil or claim.pid == pid do
      state = if claim, do: state, else: start_claim(state, id, pid)
      {:reply, :ok, watch(state, pid)}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :output_owned}, state}
    end
  end

  def handle_call({:set_output, id, value}, {pid, _}, state) do
    state = sweep(state)

    with :ok <- writable(state, id),
         %{pid: ^pid} <- state.claims[id],
         true <- Definition.desired?(state.definitions[id], value) do
      state =
        if state.desires[id] === value,
          do: state,
          else: put_in(state.claims[id].changed_at_ms, System.monotonic_time(:millisecond))

      {:reply, :ok, put_in(state.desires[id], value) |> notify_output(id)}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :invalid_output_write}, state}
    end
  end

  def handle_call({:release_output, id}, {pid, _}, state) do
    state = sweep(state)

    case state.claims[id] do
      %{pid: ^pid} -> {:reply, :ok, clear_writer(state, id)}
      _ -> {:reply, {:error, :not_output_owner}, state}
    end
  end

  @impl true
  def handle_info(:sweep, state) do
    Process.send_after(self(), :sweep, 1_000)
    {:noreply, %{sweep(state) | clock: state.clock || subscribe_clock()}}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{clock: %{ref: ref}} = state),
    do: {:noreply, %{state | clock: nil}}

  def handle_info({:DOWN, _, :process, _, _}, state), do: {:noreply, sweep(state)}

  def handle_info({:nerves_time, :sync_status, %{synchronized?: synchronized?}}, state),
    do: {:noreply, clock_status(state, synchronized?)}

  def handle_info({:nerves_time, event, _}, state) when event in [:sync_acquired, :sync_lost],
    do: {:noreply, clock_status(state, event == :sync_acquired)}

  def handle_info(_, state), do: {:noreply, state}

  defp register(definition, pid, handler, state) do
    with true <- Definition.valid?(definition),
         {:ok, owner} <- Owner.resolve(pid),
         true <- handler == nil or (alive?(handler) and Owner.matches?(handler, owner)),
         id = owner.app <> "." <> definition.id,
         :ok <- compatible(state, id, definition, pid, handler, owner) do
      save_registration(state, id, definition, %{
        pid: pid,
        handler: handler,
        owner: owner,
        dirty?: false,
        active?: true
      })
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :invalid_registration}, state}
    end
  end

  defp compatible(state, id, definition, pid, handler, owner) do
    cond do
      state.definitions[id] not in [nil, definition] ->
        {:error, :definition_conflict}

      state.bindings[id] == nil ->
        :ok

      Map.take(state.bindings[id], [:pid, :handler, :owner]) ==
          %{pid: pid, handler: handler, owner: owner} ->
        :ok

      true ->
        {:error, :endpoint_owned}
    end
  end

  defp save_registration(state, id, definition, binding) do
    case persist_definition(state, id, definition) do
      :ok ->
        state = put_in(state.definitions[id], definition)

        state =
          %{state | bindings: Map.put_new(state.bindings, id, binding)} |> watch(binding.pid)

        state =
          if binding.handler, do: watch(state, binding.handler), else: notify_input(state, id)

        {:reply, {:ok, id}, state}

      {:error, :io_catalog_write_failed} = error ->
        {:reply, error, %{state | storage_error: error}}

      error ->
        {:reply, error, state}
    end
  end

  defp persist_definition(%{storage_error: error}, _, _) when error != nil, do: error

  defp persist_definition(state, id, definition) do
    if Map.has_key?(state.definitions, id),
      do: :ok,
      else: Catalog.save(state.path, Map.put(state.definitions, id, definition))
  end

  defp caller_binding(state, pid, local_id) do
    with true <- Definition.local_id?(local_id),
         {:ok, owner} <- Owner.resolve(pid, :release),
         id = owner.app <> "." <> local_id,
         %{owner: ^owner} = binding <- state.bindings[id] do
      {:ok, id, binding}
    else
      _ -> {:error, :endpoint_unavailable}
    end
  end

  defp writable(state, id) do
    cond do
      not match?(%OutputDefinition{}, state.definitions[id]) -> {:error, :unknown_output}
      not available?(state.bindings[id]) -> {:error, :endpoint_unavailable}
      true -> :ok
    end
  end

  defp available?(nil), do: false
  defp available?(binding), do: Owner.valid?(binding.owner)

  # Unique and increasing for the controller's lifetime; a restarted controller has
  # no bindings, so no earlier epoch can be reported to it.
  defp start_claim(state, id, pid) do
    claim = %{
      pid: pid,
      epoch: :erlang.unique_integer([:positive, :monotonic]),
      changed_at_ms: System.monotonic_time(:millisecond)
    }

    put_in(state.claims[id], claim) |> notify_output(id)
  end

  defp epoch(state, id), do: get_in(state.claims, [id, :epoch])

  defp outcome?(outcome), do: outcome in [:applied, :unknown] or match?({:failed, _}, outcome)

  defp input_snapshot(state, id) do
    case state.definitions[id] do
      %InputDefinition{} = definition ->
        {:ok,
         %{
           id: id,
           definition: definition,
           available?: available?(state.bindings[id]),
           reading: state.latest[id],
           stale?:
             Definition.stale?(definition, state.latest[id], System.monotonic_time(:millisecond))
         }}

      _ ->
        {:error, :unknown_input}
    end
  end

  defp output_snapshot(state, id, caller, now) do
    case state.definitions[id] do
      %OutputDefinition{} = definition ->
        claim = state.claims[id]
        desired = state.desires[id]

        desire =
          if claim && desired != nil,
            do: %{value: desired, epoch: claim.epoch, changed_at_ms: claim.changed_at_ms}

        inputs =
          Map.new(definition.evidence, fn evidence ->
            {evidence.input,
             case input_snapshot(state, evidence.input) do
               {:ok, snapshot} -> snapshot
               _ -> nil
             end}
          end)

        {:ok,
         %{
           id: id,
           definition: definition,
           available?: available?(state.bindings[id]),
           claimed?: claim != nil,
           owned?: claim != nil and claim.pid == caller,
           desired: desired,
           status: OutputStatus.derive(definition, desire, state.applied[id], inputs, now)
         }}

      _ ->
        {:error, :unknown_output}
    end
  end

  defp notify_input(state, id) do
    subscribers =
      Map.new(state.subscribers, fn {pid, subscriptions} ->
        if Map.get(subscriptions, id) == false do
          send(pid, {:nerves_gate_input_changed, id})
          {pid, Map.put(subscriptions, id, true)}
        else
          {pid, subscriptions}
        end
      end)

    %{state | subscribers: subscribers}
  end

  defp clean_input(state, pid, id) do
    if Map.has_key?(Map.get(state.subscribers, pid, %{}), id),
      do: put_in(state.subscribers[pid][id], false),
      else: state
  end

  defp notify_output(state, id) do
    case state.bindings[id] do
      %{handler: handler, dirty?: false} when is_pid(handler) ->
        send(handler, {:nerves_gate_output_changed, state.definitions[id].id})
        put_in(state.bindings[id].dirty?, true)

      _ ->
        state
    end
  end

  defp clear_writer(state, id) do
    %{
      state
      | claims: Map.delete(state.claims, id),
        desires: Map.delete(state.desires, id),
        applied: Map.delete(state.applied, id)
    }
    |> notify_output(id)
  end

  defp sweep(state) do
    state =
      Enum.reduce(state.bindings, state, fn {id, binding}, acc ->
        refresh_binding(acc, id, binding)
      end)

    state =
      Enum.reduce(state.claims, state, fn {id, %{pid: pid}}, acc ->
        if live_owner?(state, pid, :active), do: acc, else: clear_writer(acc, id)
      end)

    subscribers =
      Map.filter(state.subscribers, fn {pid, inputs} ->
        live_owner?(state, pid, :release) and map_size(inputs) > 0
      end)

    unwatch_unused(%{state | subscribers: subscribers})
  end

  defp refresh_binding(state, id, binding) do
    cond do
      not live_binding?(binding) ->
        drop_binding(state, id)

      binding.active? != Owner.valid?(binding.owner) ->
        state = put_in(state.bindings[id].active?, Owner.valid?(binding.owner))
        if binding.handler, do: notify_output(state, id), else: notify_input(state, id)

      true ->
        state
    end
  end

  defp live_binding?(binding) do
    alive?(binding.pid) and Owner.matches?(binding.pid, binding.owner, :release) and
      (binding.handler == nil or
         (alive?(binding.handler) and Owner.matches?(binding.handler, binding.owner, :release)))
  end

  defp drop_binding(state, id) do
    state =
      if state.bindings[id].handler, do: clear_writer(state, id), else: notify_input(state, id)

    %{state | bindings: Map.delete(state.bindings, id), latest: Map.delete(state.latest, id)}
  end

  defp alive?(pid), do: is_pid(pid) and node(pid) == node() and Process.alive?(pid)

  defp watch(state, pid) do
    if Map.has_key?(state.monitors, pid) do
      state
    else
      owner =
        case Owner.resolve(pid, :release) do
          {:ok, owner} -> owner
          _ -> nil
        end

      put_in(state.monitors[pid], %{ref: Process.monitor(pid), owner: owner})
    end
  end

  # Local administrative consumers have no plugin generation. Managed consumers
  # must not keep subscriptions or Desires alive after their activation is revoked.
  defp live_owner?(state, pid, mode) do
    alive?(pid) and
      case state.monitors[pid] do
        %{owner: nil} -> true
        %{owner: owner} -> Owner.matches?(pid, owner, mode)
        _ -> false
      end
  end

  defp unwatch_unused(state) do
    bound = Enum.flat_map(state.bindings, fn {_, binding} -> [binding.pid, binding.handler] end)
    writers = Enum.map(state.claims, fn {_, claim} -> claim.pid end)
    used = MapSet.new(bound ++ writers ++ Map.keys(state.subscribers))

    monitors =
      Map.filter(state.monitors, fn {pid, %{ref: ref}} ->
        if MapSet.member?(used, pid) do
          true
        else
          Process.demonitor(ref, [:flush])
          false
        end
      end)

    %{state | monitors: monitors}
  end

  defp consume_hint(kind, id) do
    receive do
      {^kind, ^id} -> consume_hint(kind, id)
    after
      0 -> :ok
    end
  end

  defp subscribe_clock do
    case Process.whereis(NervesTime.Ntpd) do
      nil ->
        nil

      pid ->
        :ok = NervesTime.subscribe()
        %{pid: pid, ref: Process.monitor(pid), synchronized?: false}
    end
  catch
    :exit, _ -> nil
  end

  defp clock_status(%{clock: nil} = state, _), do: state
  defp clock_status(state, synchronized?), do: put_in(state.clock.synchronized?, synchronized?)

  defp utc(%{pid: pid, synchronized?: true}) do
    if Process.alive?(pid), do: DateTime.utc_now()
  end

  defp utc(_), do: nil
end

defmodule NervesGate.IO do
  @moduledoc """
  Observable inputs and process-owned, runtime-only desired outputs.

  Plugins register and publish using local IDs in their managed activation. Readers
  and writers use full IDs. Subscribe before reading; monitor the returned controller
  PID and subscribe afresh after its loss. A snapshot read consumes this caller's
  outstanding hint. Changes coalesce until that read, never silently disappear.

  Only the bound plugin handler reads desire via `read_desired/1`. Plugins own all
  physical reconciliation, retries and shutdown. A successful `set_output/2` stores
  desire only. Release, process loss and restart cause no implicit device operation.
  Feedback is an ordinary input; this domain provides no command or safety guarantee.
  """
  use GenServer
  alias NervesGate.IO.{Catalog, Definition}
  alias NervesGate.Plugins.Owner
  alias NervesGateSDK.IO.{InputDefinition, Observation, OutputDefinition}

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Register a persisted input definition in the actual calling plugin's namespace."
  def register_input(%InputDefinition{} = definition),
    do: GenServer.call(__MODULE__, {:register_input, definition})

  def register_input(_), do: {:error, :invalid_definition}

  @doc "Bind a repeatable output to a supervised handler in the calling plugin's activation."
  def register_output(%OutputDefinition{} = definition, handler) when is_pid(handler),
    do: GenServer.call(__MODULE__, {:register_output, definition, handler})

  def register_output(_, _), do: {:error, :invalid_definition}

  @doc "Replace the caller's input observation, including invalid/unknown samples."
  def publish_input(local_id, value, quality \\ :good),
    do: GenServer.call(__MODULE__, {:publish_input, local_id, value, quality})

  @doc "Read the bound handler's current target; nil means no active desire, never a default."
  def read_desired(local_id) do
    consume_hint(:nerves_gate_output_changed, local_id)
    GenServer.call(__MODULE__, {:read_desired, local_id})
  end

  @doc "Read persisted definitions, independent of live availability."
  def definitions, do: GenServer.call(__MODULE__, :definitions)

  @doc "Read latest state, quality and monotonic freshness. Consumes this caller's input hint."
  def input(full_id) do
    consume_hint(:nerves_gate_input_changed, full_id)
    GenServer.call(__MODULE__, {:input, full_id})
  end

  @doc """
  Read desire and optional ordinary input feedback, never a write outcome. `owned?`
  is relative to the actual caller; other writers stay private.
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

  @doc "Exclusively claim an available output for the actual calling PID, without setting desire."
  def claim_output(full_id), do: GenServer.call(__MODULE__, {:claim_output, full_id})

  @doc "Set the caller-owned desired value. Success says nothing about physical device state."
  def set_output(full_id, value), do: GenServer.call(__MODULE__, {:set_output, full_id, value})

  @doc "Clear this caller's desire and ownership. Does not revert or stop the equipment."
  def release_output(full_id), do: GenServer.call(__MODULE__, {:release_output, full_id})

  @impl true
  def init(opts) do
    path = Keyword.get(opts, :path, "/data/nerves_gate/io.term")

    case Catalog.load(path) do
      {:ok, definitions} ->
        Process.send_after(self(), :sweep, 1_000)

        {:ok,
         %{
           path: path,
           definitions: definitions,
           bindings: %{},
           latest: %{},
           desires: %{},
           writers: %{},
           subscribers: %{},
           monitors: %{},
           storage_error: nil,
           clock: subscribe_clock()
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:register_input, definition}, {pid, _}, state),
    do: register(definition, pid, nil, sweep(state))

  def handle_call({:register_output, definition, handler}, {pid, _}, state),
    do: register(definition, pid, handler, sweep(state))

  def handle_call(:definitions, _, state), do: {:reply, state.definitions, sweep(state)}

  def handle_call({:publish_input, local_id, value, quality}, {pid, _}, state) do
    state = sweep(state)

    with {:ok, id, binding} <- caller_binding(state, pid, local_id),
         %InputDefinition{} = definition <- state.definitions[id],
         true <- binding.pid == pid,
         true <- Definition.observation?(definition, value, quality) do
      observation = %Observation{
        input_id: id,
        value: value,
        quality: quality,
        received_at_ms: System.monotonic_time(:millisecond),
        received_at_utc: utc(state.clock)
      }

      state = put_in(state.latest[id], observation) |> notify_input(id)
      {:reply, {:ok, observation}, state}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :invalid_publication}, state}
    end
  end

  def handle_call({:read_desired, local_id}, {pid, _}, state) do
    state = sweep(state)

    case caller_binding(state, pid, local_id) do
      {:ok, id, %{handler: ^pid}} ->
        {:reply, {:ok, state.desires[id]}, put_in(state.bindings[id].dirty?, false)}

      {:error, _} = error ->
        {:reply, error, state}

      _ ->
        {:reply, {:error, :not_output_handler}, state}
    end
  end

  def handle_call({:input, id}, {pid, _}, state) do
    state = sweep(state)
    {:reply, input_snapshot(state, id), clean_input(state, pid, id)}
  end

  def handle_call({:output, id}, {pid, _}, state) do
    state = sweep(state)
    {:reply, output_snapshot(state, id, pid), state}
  end

  def handle_call(:snapshot, {pid, _}, state) do
    state = sweep(state)
    ids = state.definitions |> Map.keys() |> Enum.sort()

    {:reply,
     %{
       inputs: for(id <- ids, {:ok, input} <- [input_snapshot(state, id)], do: input),
       outputs: for(id <- ids, {:ok, output} <- [output_snapshot(state, id, pid)], do: output)
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
         true <- state.writers[id] in [nil, pid] do
      {:reply, :ok, put_in(state.writers[id], pid) |> watch(pid)}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :output_owned}, state}
    end
  end

  def handle_call({:set_output, id, value}, {pid, _}, state) do
    state = sweep(state)

    with :ok <- writable(state, id),
         true <- state.writers[id] == pid,
         true <- Definition.desired?(state.definitions[id], value) do
      state = put_in(state.desires[id], value) |> notify_output(id)
      {:reply, :ok, state}
    else
      {:error, _} = error -> {:reply, error, state}
      _ -> {:reply, {:error, :invalid_output_write}, state}
    end
  end

  def handle_call({:release_output, id}, {pid, _}, state) do
    state = sweep(state)

    if state.writers[id] == pid do
      {:reply, :ok, clear_writer(state, id)}
    else
      {:reply, {:error, :not_output_owner}, state}
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

  defp input_snapshot(state, id) do
    case state.definitions[id] do
      %InputDefinition{} = definition ->
        {:ok,
         %{
           id: id,
           definition: definition,
           available?: available?(state.bindings[id]),
           observation: state.latest[id],
           stale?:
             Definition.stale?(definition, state.latest[id], System.monotonic_time(:millisecond))
         }}

      _ ->
        {:error, :unknown_input}
    end
  end

  defp output_snapshot(state, id, caller) do
    case state.definitions[id] do
      %OutputDefinition{} = definition ->
        {:ok,
         %{
           id: id,
           definition: definition,
           available?: available?(state.bindings[id]),
           claimed?: Map.has_key?(state.writers, id),
           owned?: state.writers[id] == caller,
           desired: state.desires[id],
           reported: feedback(state, id, definition)
         }}

      _ ->
        {:error, :unknown_output}
    end
  end

  defp feedback(_, _, %{feedback_input_id: nil}), do: nil

  defp feedback(state, id, definition) do
    [app, _] = String.split(id, ".", parts: 2)

    case input_snapshot(state, app <> "." <> definition.feedback_input_id) do
      {:ok, %{definition: %{type: type, unit: unit}} = snapshot}
      when type == definition.type and unit == definition.unit ->
        snapshot

      _ ->
        nil
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
    %{state | writers: Map.delete(state.writers, id), desires: Map.delete(state.desires, id)}
    |> notify_output(id)
  end

  defp sweep(state) do
    state =
      Enum.reduce(state.bindings, state, fn {id, binding}, acc ->
        refresh_binding(acc, id, binding)
      end)

    state =
      Enum.reduce(state.writers, state, fn {id, pid}, acc ->
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
  # must not keep subscriptions or desire alive after their activation is revoked.
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
    used = MapSet.new(bound ++ Map.values(state.writers) ++ Map.keys(state.subscribers))

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

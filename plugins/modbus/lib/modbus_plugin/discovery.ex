defmodule ModbusPlugin.Discovery do
  @moduledoc "A bounded read-only survey. Raw evidence stays in memory until Stop; it creates no ranges or endpoints."
  use GenServer, restart: :temporary
  alias ModbusPlugin.{Connection, Protocol}
  @max_evidence 4096

  def start_link({config, plan}),
    do:
      GenServer.start_link(__MODULE__, {config, plan},
        name: {:via, Registry, {ModbusPlugin.Registry, config.id}}
      )

  def validate(params) when is_map(params) do
    units = params["units"]
    ranges = params["ranges"] || []
    budget = params["budget"] || 200
    delay = params["delay"] || 50

    with :ok <-
           check(
             Enum.all?(Map.keys(params), &(&1 in ~w(units ranges budget delay identify))),
             "discovery",
             :unknown_field
           ),
         :ok <- check(is_list(units) and length(units) in 1..16, "units", units),
         :ok <-
           check(Enum.all?(units, &(&1 in 1..247)) and Enum.uniq(units) == units, "units", units),
         :ok <- check(is_list(ranges) and length(ranges) <= 8, "ranges", ranges),
         {:ok, ranges} <- ranges(ranges),
         :ok <- check(params["identify"] in [nil, true, false], "identify", params["identify"]),
         :ok <- check(is_integer(budget) and budget in 1..1000, "budget", budget),
         :ok <- check(is_integer(delay) and delay in 0..5000, "delay", delay) do
      {:ok,
       %{
         units: units,
         ranges: ranges,
         identify: params["identify"] != false,
         budget: budget,
         delay: delay
       }}
    end
  end

  def validate(params), do: {:error, {:invalid_field, "discovery", params}}

  defp ranges(ranges) do
    Enum.reduce_while(ranges, {:ok, [], 0}, fn range, {:ok, acc, total} ->
      table =
        is_map(range) && Enum.find(Protocol.tables(), &(Atom.to_string(&1) == range["table"]))

      address = is_map(range) && range["address"]
      count = is_map(range) && range["count"]

      if table && is_integer(address) && is_integer(count) && address in 0..65535 &&
           count in 1..4096 && address + count - 1 <= 65535 && total + count <= 4096,
         do:
           {:cont, {:ok, [%{table: table, address: address, count: count} | acc], total + count}},
         else: {:halt, {:error, {:invalid_field, "ranges", range}}}
    end)
    |> case do
      {:ok, ranges, _} -> {:ok, Enum.reverse(ranges)}
      error -> error
    end
  end

  defp check(true, _, _), do: :ok
  defp check(_, field, value), do: {:error, {:invalid_field, field, value}}

  def init({config, plan}) do
    Process.flag(:trap_exit, true)

    case Connection.start_client(config) do
      {:ok, client} ->
        send(self(), :step)
        queue = for unit <- plan.units, op <- operations(plan, unit), do: op

        {:ok,
         %{
           config: config,
           plan: plan,
           client: client,
           queue: queue,
           pending: nil,
           requests: 0,
           state: :discovering,
           error: nil,
           units: Map.new(plan.units, &{&1, %{unit: &1, tables: %{}}}),
           evidence: [],
           failures: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp operations(plan, unit) do
    identify = if plan.identify, do: [{:identify, unit, 0}, {:server_id, unit}], else: []
    probes = for table <- Protocol.tables(), do: {:probe, unit, table}

    reads =
      for range <- plan.ranges,
          {address, count} <- chunks(range.address, range.count, Protocol.limit(range.table)),
          do: {:read, unit, range.table, address, count}

    identify ++ probes ++ reads
  end

  defp chunks(address, count, limit) when count <= limit, do: [{address, count}]

  defp chunks(address, count, limit),
    do: [{address, limit} | chunks(address + limit, count - limit, limit)]

  def handle_call(:status, _, state) do
    {:reply,
     %{
       state: state.state,
       error: state.error,
       discovery: %{
         requests: state.requests,
         budget: state.plan.budget,
         remaining: length(state.queue),
         units: state.units |> Map.values() |> Enum.sort_by(& &1.unit),
         evidence: Enum.reverse(state.evidence),
         failures: Enum.reverse(state.failures)
       }
     }, state}
  end

  def handle_call({:write, _, _}, _, state), do: {:reply, {:error, :discovering}, state}
  def handle_call({:put, _, _}, _, state), do: {:reply, {:error, :discovering}, state}

  def handle_info(:step, %{state: :discovering, pending: nil, queue: [op | queue]} = state) do
    cond do
      state.requests >= state.plan.budget ->
        {:noreply, finish(state, :budget_exhausted)}

      length(state.evidence) >= @max_evidence ->
        {:noreply, finish(state, :evidence_limit)}

      true ->
        ref =
          Modbus.Client.send_request(state.client, elem(op, 1), request(op),
            timeout: state.config.timeout
          )

        {:noreply, %{state | queue: queue, pending: {ref, op}, requests: state.requests + 1}}
    end
  end

  def handle_info(:step, %{state: :discovering, pending: nil, queue: []} = state),
    do: {:noreply, finish(state, nil)}

  def handle_info({Modbus.Client, ref, result}, %{pending: {ref, op}} = state) do
    state = record(%{state | pending: nil}, op, result)
    Process.send_after(self(), :step, state.plan.delay)
    {:noreply, state}
  end

  def handle_info({:EXIT, client, reason}, %{client: client, state: :discovering} = state),
    do: {:noreply, %{finish(state, {:client_exit, reason}) | client: nil}}

  def handle_info(_, state), do: {:noreply, state}

  def terminate(_, state) do
    if state.client && Process.alive?(state.client), do: Modbus.Client.stop(state.client)
    :ok
  end

  defp finish(state, error) do
    if state.client && Process.alive?(state.client), do: Modbus.Client.stop(state.client)
    %{state | state: :discovered, error: error, client: nil}
  end

  defp request({:identify, _, from}), do: {:read_device_identification, :basic, from}
  defp request({:server_id, _}), do: :report_server_id
  defp request({:probe, _, table}), do: {Protocol.function(table), 0, 1}
  defp request({:read, _, table, address, count}), do: {Protocol.function(table), address, count}

  defp record(state, {:identify, unit, from}, {:ok, answer}) do
    previous = Map.get(state.units[unit], :identification, %{objects: []})
    objects = Enum.uniq_by(previous.objects ++ answer.objects, &elem(&1, 0))
    state = put_unit(state, unit, :identification, %{objects: objects, more: answer.more_follows})

    if answer.more_follows and answer.next_object_id > from,
      do: %{state | queue: [{:identify, unit, answer.next_object_id} | state.queue]},
      else: state
  end

  defp record(state, {:identify, unit, _}, result),
    do: put_unit(state, unit, :identification, outcome(result))

  defp record(state, {:server_id, unit}, {:ok, data}),
    do: put_unit(state, unit, :server_id, Base.encode16(data))

  defp record(state, {:server_id, unit}, result),
    do: put_unit(state, unit, :server_id, outcome(result))

  defp record(state, {:probe, unit, table}, result),
    do:
      update_in(
        state.units[unit].tables,
        &Map.put(&1, table, if(match?({:ok, _}, result), do: :ok, else: outcome(result)))
      )

  defp record(state, {:read, unit, table, address, count}, {:ok, values})
       when length(values) == count do
    at = DateTime.to_iso8601(DateTime.utc_now())

    observations =
      for {raw, offset} <- Enum.with_index(values),
          do: %{unit: unit, table: table, address: address + offset, raw: raw, observed_at: at}

    room = @max_evidence - length(state.evidence)
    state = %{state | evidence: Enum.reverse(Enum.take(observations, room)) ++ state.evidence}
    if count > room, do: finish(state, :evidence_limit), else: state
  end

  defp record(
         state,
         {:read, unit, table, address, count},
         {:error, {:exception, :illegal_data_address}}
       )
       when count > 1 do
    half = div(count, 2)

    %{
      state
      | queue: [
          {:read, unit, table, address, half},
          {:read, unit, table, address + half, count - half} | state.queue
        ]
    }
  end

  defp record(state, {:read, unit, table, address, count}, result) do
    failure = %{unit: unit, table: table, address: address, count: count, result: outcome(result)}
    %{state | failures: [failure | state.failures]}
  end

  defp put_unit(state, unit, key, value),
    do: update_in(state.units[unit], &Map.put(&1, key, value))

  defp outcome({:error, {:exception, exception}}), do: {:exception, exception}
  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome(other), do: {:error, {:unexpected_response, other}}
end

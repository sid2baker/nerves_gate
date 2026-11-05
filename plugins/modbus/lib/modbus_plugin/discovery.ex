defmodule ModbusPlugin.Discovery do
  @moduledoc """
  One explicitly requested, read-only survey of a remote device through a saved,
  stopped client definition. It runs instead of polling on that definition's
  transport and only ever sends FC01-04 reads, FC17 Report Server ID and FC43/14
  Device Identification: never a write function code.

  For each requested unit it identifies the device, probes which read functions
  answer at address 0 and, when asked, looks for a SunSpec marker at 0, 40000 and
  50000 and walks the model headers. Requested address ranges are read in
  protocol-sized chunks; a chunk refused as an illegal address is split in half
  until single points remain, so gaps between implemented points cost requests,
  not results. Every request counts against the budget and requests are paced.

  Results are raw evidence held in memory until the definition is stopped. They
  claim no meaning and register no endpoints; `mapping/1` turns one observation
  into a draft mapping the operator still names, types and saves.
  """
  use GenServer, restart: :temporary
  alias ModbusPlugin.{Connection, Plan}

  @max_units 16
  @max_ranges 8
  @max_addresses 4_096
  @max_budget 1_000
  @max_evidence 4_096
  @max_models 64
  @sunspec_bases [0, 40_000, 50_000]
  @marker [0x5375, 0x6E53]

  def start_link({config, plan}),
    do:
      GenServer.start_link(__MODULE__, {config, plan},
        name: {:via, Registry, {ModbusPlugin.Registry, config.id}}
      )

  @doc """
  Validate a discovery request: `units` (1-16 IDs in 1..247), optional `ranges`
  (`table`, `address`, `count`; at most 4096 addresses in total), `identify`
  and `sunspec` booleans, `budget` (requests, 1..1000) and `delay` (ms between
  requests, 0..5000).
  """
  def validate(params) when is_map(params) do
    units = params["units"]
    ranges = params["ranges"] || []
    budget = params["budget"] || 200
    delay = params["delay"] || 50

    with :ok <- check(is_list(units) and length(units) in 1..@max_units, "units", units),
         :ok <-
           check(Enum.all?(units, &(&1 in 1..247)) and Enum.uniq(units) == units, "units", units),
         :ok <- check(is_list(ranges) and length(ranges) <= @max_ranges, "ranges", ranges),
         {:ok, ranges} <- ranges(ranges),
         :ok <- check(params["identify"] in [nil, true, false], "identify", params["identify"]),
         :ok <- check(params["sunspec"] in [nil, true, false], "sunspec", params["sunspec"]),
         :ok <- check(is_integer(budget) and budget in 1..@max_budget, "budget", budget),
         :ok <- check(is_integer(delay) and delay in 0..5_000, "delay", delay) do
      {:ok,
       %{
         units: units,
         ranges: ranges,
         identify: params["identify"] != false,
         sunspec: params["sunspec"] == true,
         budget: budget,
         delay: delay
       }}
    end
  end

  def validate(params), do: {:error, {:invalid_field, "discovery", params}}

  @doc "A draft mapping for one observation; the operator chooses the ID, type and meaning."
  def mapping(%{table: table, address: address}),
    do: %{"id" => "#{table}_#{address}", "table" => Atom.to_string(table), "address" => address}

  defp ranges(ranges) do
    ranges
    |> Enum.reduce_while({:ok, [], 0}, fn range, {:ok, acc, total} ->
      table = is_map(range) && Enum.find(Plan.tables(), &(Atom.to_string(&1) == range["table"]))
      address = is_map(range) && range["address"]
      count = is_map(range) && range["count"]

      if table && is_integer(address) && is_integer(count) && address in 0..65535 &&
           count in 1..@max_addresses && address + count - 1 <= 65535 &&
           total + count <= @max_addresses,
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

  @impl true
  def init({config, plan}) do
    Process.flag(:trap_exit, true)

    case Connection.start_client(config) do
      {:ok, client} ->
        send(self(), :step)

        {:ok,
         %{
           config: config,
           plan: plan,
           client: client,
           queue: queue(plan),
           pending: nil,
           requests: 0,
           state: :discovering,
           error: nil,
           started_at: now(),
           units: Map.new(plan.units, &{&1, %{unit: &1, tables: %{}}}),
           sunspec: [],
           evidence: [],
           failures: []
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp queue(plan) do
    for unit <- plan.units, op <- unit_ops(plan, unit), do: op
  end

  defp unit_ops(plan, unit) do
    identify = if plan.identify, do: [{:identify, unit, 0}, {:server_id, unit}], else: []
    probes = for table <- Plan.tables(), do: {:probe, unit, table}
    sunspec = if plan.sunspec, do: Enum.map(@sunspec_bases, &{:marker, unit, &1}), else: []

    reads =
      for range <- plan.ranges,
          {address, count} <- chunks(range.address, range.count, Plan.limit(range.table)),
          do: {:read, unit, range.table, address, count}

    identify ++ probes ++ sunspec ++ reads
  end

  defp chunks(address, count, limit) when count <= limit, do: [{address, count}]

  defp chunks(address, count, limit),
    do: [{address, limit} | chunks(address + limit, count - limit, limit)]

  @impl true
  def handle_call(:status, _, state) do
    {:reply,
     %{
       state: state.state,
       values: nil,
       error: state.error,
       read_at: nil,
       discovery: %{
         started_at: state.started_at,
         requests: state.requests,
         budget: state.plan.budget,
         remaining: length(state.queue),
         units: state.units |> Map.values() |> Enum.sort_by(& &1.unit),
         sunspec: Enum.reverse(state.sunspec),
         evidence: Enum.reverse(state.evidence),
         failures: Enum.reverse(state.failures)
       }
     }, state}
  end

  def handle_call({:write, _, _}, _, state), do: {:reply, {:error, :discovering}, state}

  @impl true
  def handle_cast({:forget, _}, state), do: {:noreply, state}

  @impl true
  def handle_info(:step, %{state: :discovering, pending: nil, queue: [op | queue]} = state) do
    if state.requests >= state.plan.budget or length(state.evidence) >= @max_evidence do
      reason =
        if state.requests >= state.plan.budget, do: :budget_exhausted, else: :evidence_limit

      {:noreply, finish(state, reason)}
    else
      ref =
        Modbus.Client.send_request(state.client, unit(op), request(op),
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

  @impl true
  def terminate(_, state) do
    if state.client && Process.alive?(state.client), do: Modbus.Client.stop(state.client)
    :ok
  end

  # The transport closes as soon as the survey ends; evidence stays for review.
  defp finish(state, error) do
    if state.client && Process.alive?(state.client), do: Modbus.Client.stop(state.client)
    %{state | state: :discovered, error: error, client: nil}
  end

  defp unit({_, unit}), do: unit
  defp unit(op), do: elem(op, 1)

  defp request({:identify, _, from}), do: {:read_device_identification, :basic, from}
  defp request({:server_id, _}), do: :report_server_id
  defp request({:probe, _, table}), do: {Plan.function(table), 0, 1}
  defp request({:marker, _, base}), do: {:read_holding_registers, base, 2}
  defp request({:model, _, _, address}), do: {:read_holding_registers, address, 2}
  defp request({:read, _, table, address, count}), do: {Plan.function(table), address, count}

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

  defp record(state, {kind, unit}, result) when kind in [:identify, :server_id],
    do:
      put_unit(
        state,
        unit,
        if(kind == :identify, do: :identification, else: :server_id),
        outcome(result)
      )

  defp record(state, {:probe, unit, table}, result) do
    outcome = if match?({:ok, _}, result), do: :ok, else: outcome(result)
    update_in(state.units[unit].tables, &Map.put(&1, table, outcome))
  end

  defp record(state, {:marker, unit, base}, {:ok, @marker}),
    do: %{
      state
      | queue: [{:model, unit, base, base + 2} | state.queue],
        sunspec: [%{unit: unit, base: base, models: []} | state.sunspec]
    }

  defp record(state, {:marker, _, _}, _), do: state

  defp record(state, {:model, unit, base, address}, {:ok, [id, length]}) do
    [found | rest] = state.sunspec

    cond do
      id == 0xFFFF ->
        %{state | sunspec: [%{found | models: Enum.reverse(found.models)} | rest]}

      length(found.models) >= @max_models or address + 2 + length > 65535 ->
        %{
          state
          | sunspec: [
              Map.merge(found, %{models: Enum.reverse(found.models), error: :model_limit}) | rest
            ]
        }

      true ->
        model = %{id: id, address: address, length: length}

        %{
          state
          | sunspec: [%{found | models: [model | found.models]} | rest],
            queue: [{:model, unit, base, address + 2 + length} | state.queue]
        }
    end
  end

  defp record(state, {:model, _, _, _}, result) do
    [found | rest] = state.sunspec

    %{
      state
      | sunspec: [
          Map.merge(found, %{models: Enum.reverse(found.models), error: outcome(result)}) | rest
        ]
    }
  end

  defp record(state, {:read, unit, table, address, count}, {:ok, values})
       when length(values) == count do
    at = now()

    observations =
      for {raw, offset} <- Enum.with_index(values),
          do: observation(unit, table, address + offset, raw, at)

    room = @max_evidence - length(state.evidence)
    state = %{state | evidence: Enum.reverse(Enum.take(observations, room)) ++ state.evidence}
    if count > room, do: finish(state, :evidence_limit), else: state
  end

  # Gaps are common: split a refused chunk until single implemented points answer.
  defp record(
         state,
         {:read, unit, table, address, count},
         {:error, {:exception, :illegal_data_address}}
       )
       when count > 1 do
    half = div(count, 2)

    split = [
      {:read, unit, table, address, half},
      {:read, unit, table, address + half, count - half}
    ]

    %{state | queue: split ++ state.queue}
  end

  defp record(state, {:read, unit, table, address, count}, result) do
    failure = %{
      unit: unit,
      table: table,
      address: address,
      count: count,
      result: outcome(result),
      observed_at: now()
    }

    %{state | failures: [failure | state.failures]}
  end

  defp observation(unit, table, address, raw, at) when is_boolean(raw),
    do: %{unit: unit, table: table, address: address, raw: raw, observed_at: at}

  defp observation(unit, table, address, raw, at),
    do: %{
      unit: unit,
      table: table,
      address: address,
      raw: raw,
      hex: raw |> Integer.to_string(16) |> String.pad_leading(4, "0"),
      observed_at: at
    }

  defp put_unit(state, unit, key, value),
    do: update_in(state.units[unit], &Map.put(&1, key, value))

  defp outcome({:error, {:exception, exception}}), do: {:exception, exception}
  defp outcome({:error, reason}), do: {:error, reason}
  defp outcome(other), do: {:error, {:unexpected_response, other}}

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end

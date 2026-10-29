defmodule NervesGateSDK.Output do
  @moduledoc """
  Plugin-side runtime that applies Desires to hardware.

  Start it under the plugin's own supervision with the output definitions it
  handles and a callback module implementing `c:apply/3`. The runtime registers the
  outputs with itself as handler, runs `apply/3` in its own (plugin-owned) process,
  serializes calls and always applies the newest Desire. It hides change hints,
  reading Desires, claim epochs and reporting Apply outcomes.

  `apply/3` receives the typed Desire, or `nil` once an applied Desire ends. `nil`
  means: perform the plugin's declared release behaviour (for example hold); the
  platform never writes a fallback value. The runtime never calls `apply/3` with
  `nil` merely because it started, so registration causes no physical write.

  Return `:applied` only when the operation appeared successful, `:unknown` when it
  may or may not have happened, or `{:failed, reason}`. Outcomes for an ended claim
  or an already superseded Desire are discarded. The runtime does not retry; a
  callback that knows its operation is repeatable may call `reapply_after/2`, and
  other plugin processes may call `reapply/2`, for example after a reconnect or
  when readback disagrees.

  A module defining `apply/3` must call `Kernel.apply/3` qualified.
  If the platform no longer accepts the handler (controller restart, plugin stop),
  the runtime stops; restarting it registers afresh and starts without a Desire.
  """
  use GenServer
  alias NervesGateSDK.Backend
  alias NervesGateSDK.IO.OutputDefinition

  @type outcome :: :applied | :unknown | {:failed, term()}

  @callback apply(id :: String.t(), desired :: NervesGateSDK.IO.value() | nil, state :: term()) ::
              {outcome(), term()}

  @doc "Register `definitions` with a new runtime as handler; fails before any `apply/3`."
  def start_link(module, definitions, state, options \\ []) when is_atom(module),
    do: GenServer.start_link(__MODULE__, {module, definitions, state}, options)

  @doc "Apply the current Desire of local output `id` again, even if unchanged."
  def reapply(server, id), do: GenServer.cast(server, {:reapply, id})

  @doc "From inside `apply/3`: reapply `id`'s then-current Desire after `ms` milliseconds."
  def reapply_after(id, ms) when is_integer(ms) and ms >= 0,
    do: Process.send_after(self(), {__MODULE__, :reapply, id}, ms)

  @impl true
  def init({module, definitions, state}) do
    case register(definitions) do
      :ok ->
        outputs = Map.new(definitions, &{&1.id, %{value: nil, epoch: nil}})
        runtime = %{module: module, state: state, outputs: outputs}
        reconcile_all(runtime)

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_cast({:reapply, id}, runtime), do: reconcile(runtime, id, true)

  @impl true
  def handle_info({:nerves_gate_output_changed, id}, runtime), do: reconcile(runtime, id, false)
  def handle_info({__MODULE__, :reapply, id}, runtime), do: reconcile(runtime, id, true)
  def handle_info(_, runtime), do: {:noreply, runtime}

  defp register(definitions) do
    Enum.reduce_while(definitions, :ok, fn
      %OutputDefinition{} = definition, :ok ->
        case Backend.call(:io_register_output, [definition, self()]) do
          {:ok, _} -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, {:registration_failed, definition.id, reason}}}
        end

      definition, :ok ->
        {:halt, {:error, {:invalid_definition, definition}}}
    end)
  end

  defp reconcile_all(runtime) do
    Enum.reduce_while(Map.keys(runtime.outputs), {:ok, runtime}, fn id, {:ok, acc} ->
      case reconcile(acc, id, false) do
        {:noreply, next} -> {:cont, {:ok, next}}
        {:stop, reason, _} -> {:halt, {:stop, reason}}
      end
    end)
  end

  defp reconcile(%{outputs: outputs} = runtime, id, _) when not is_map_key(outputs, id),
    do: {:noreply, runtime}

  defp reconcile(runtime, id, force?) do
    # Reading also drains this output's queued hints in the caller.
    case Backend.call(:io_read_desired, [id]) do
      {:ok, %{desired: desired, epoch: epoch}} ->
        last = runtime.outputs[id]

        cond do
          desired == nil and last.value == nil ->
            {:noreply, put_in(runtime.outputs[id], %{value: nil, epoch: epoch})}

          desired == nil ->
            {_, state} = run(runtime, id, nil)

            {:noreply,
             %{
               runtime
               | state: state,
                 outputs: Map.put(runtime.outputs, id, %{value: nil, epoch: epoch})
             }}

          force? or {desired, epoch} != {last.value, last.epoch} ->
            {outcome, state} = run(runtime, id, desired)

            runtime = %{
              runtime
              | state: state,
                outputs: Map.put(runtime.outputs, id, %{value: desired, epoch: epoch})
            }

            report(runtime, id, epoch, desired, outcome)

          true ->
            {:noreply, runtime}
        end

      {:error, reason} ->
        {:stop, {:shutdown, {:output_unavailable, id, reason}}, runtime}
    end
  end

  defp run(runtime, id, desired) do
    case runtime.module.apply(id, desired, runtime.state) do
      {outcome, state} when outcome in [:applied, :unknown] ->
        {outcome, state}

      {{:failed, _} = outcome, state} ->
        {outcome, state}

      other ->
        raise ArgumentError, "#{inspect(runtime.module)}.apply/3 returned #{inspect(other)}"
    end
  end

  defp report(runtime, id, epoch, desired, outcome) do
    case Backend.call(:io_report_applied, [id, epoch, desired, outcome]) do
      :ok -> {:noreply, runtime}
      # A newer Desire or claim superseded this one; its hint is already queued.
      {:error, :stale_report} -> {:noreply, runtime}
      {:error, reason} -> {:stop, {:shutdown, {:output_unavailable, id, reason}}, runtime}
    end
  end
end

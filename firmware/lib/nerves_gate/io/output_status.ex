defmodule NervesGate.IO.OutputStatus do
  @moduledoc """
  Pure Status read model: whether available evidence says an output's Desire was
  achieved. Diagnostic only, never authority; it stores nothing.

  Stronger evidence wins (physical, consequence, estimate, readback, then the Apply
  outcome). Within the strongest role that has usable evidence, any disagreement is
  a mismatch, any entry still settling is pending, otherwise confirmed. Only good,
  fresh Readings received at least `settle_ms` after the Desire changed count. An
  Apply outcome alone never confirms.
  """
  alias NervesGateSDK.IO.Evidence

  @tiers %{physical: 4, consequence: 3, estimate: 2, readback: 1}
  @states %{contradicted: 3, pending: 2, confirmed: 1}

  @type state :: :confirmed | :pending | :mismatch | :unknown
  @type t :: %{
          state: state(),
          reason: String.t(),
          applied: :applied | :unknown | :failed | nil,
          evidence: [%{input: String.t(), role: atom(), state: atom()}]
        }

  @doc """
  `desire` is nil without a Desire, otherwise `%{value, epoch, changed_at_ms}`.
  `applied` is nil or `%{epoch, value, outcome}`. `inputs` maps full input IDs to
  input snapshots.
  """
  def derive(definition, desire, applied, inputs, now) do
    entries =
      for evidence <- definition.evidence do
        %{
          input: evidence.input,
          role: evidence.role,
          state: entry(definition, evidence, desire, inputs, now)
        }
      end

    applied = current(applied, desire)
    {state, reason} = verdict(definition, desire, applied, entries)
    %{state: state, reason: reason, applied: summary(applied), evidence: entries}
  end

  defp entry(_, _, nil, _, _), do: :unknown

  defp entry(definition, %Evidence{} = evidence, desire, inputs, now) do
    snapshot = inputs[evidence.input]
    # Strictly after the change: a Reading from the same millisecond may predate it.
    since = desire.changed_at_ms + evidence.settle_ms + 1

    with %{available?: true, definition: input} <- snapshot,
         {:ok, expected} <- expectation(definition, evidence.expect, desire.value, input) do
      grace = input.expected_interval_ms || max(evidence.settle_ms, 1_000)
      judge(snapshot, expected, since, since + grace, now)
    else
      _ -> :unknown
    end
  end

  # `since`: first instant a Reading counts; `deadline`: when waiting for one ends.
  defp judge(_, _, since, _, now) when now < since, do: :pending

  defp judge(%{reading: %{received_at_ms: at} = reading} = snapshot, expected, since, _, _)
       when at >= since do
    if reading.quality == :good and not snapshot.stale?,
      do: if(expected.(reading.value), do: :confirmed, else: :contradicted),
      else: :stale
  end

  defp judge(_, _, _, deadline, now) when now < deadline, do: :pending
  defp judge(%{reading: nil}, _, _, _, _), do: :unknown
  defp judge(_, _, _, _, _), do: :stale

  defp expectation(output, :equals, desired, input) do
    if input.type == output.type, do: {:ok, &(&1 == desired)}, else: :error
  end

  defp expectation(_, {:tolerance, delta}, desired, input) when input.type in [:integer, :float],
    do: {:ok, &(abs(&1 - desired) <= delta)}

  defp expectation(_, conditions, desired, input) when is_map(conditions) do
    case conditions[desired] do
      {:above, x} when input.type in [:integer, :float] ->
        {:ok, &(&1 > x)}

      {:below, x} when input.type in [:integer, :float] ->
        {:ok, &(&1 < x)}

      {:equals, value} ->
        if NervesGate.IO.Definition.value?(input.type, value),
          do: {:ok, &(&1 == value)},
          else: :error

      _ ->
        :error
    end
  end

  defp expectation(_, _, _, _), do: :error

  defp current(%{epoch: epoch, value: value} = applied, %{epoch: epoch, value: value}),
    do: applied

  defp current(_, _), do: nil

  defp verdict(_, nil, _, _), do: {:unknown, "No Desire"}

  defp verdict(definition, _, applied, entries) do
    evidence = tier(entries)

    cond do
      match?({state, _} when state in [:confirmed, :mismatch], evidence) ->
        evidence

      match?(%{outcome: {:failed, _}}, applied) ->
        {:mismatch, "Apply failed: " <> reason(applied.outcome)}

      evidence != nil ->
        evidence

      applied == nil ->
        {:pending, "Waiting for the plugin's Apply outcome"}

      definition.evidence == [] and applied.outcome == :applied ->
        {:unknown, "Applied; no evidence declared"}

      applied.outcome == :applied ->
        {:unknown, "Applied; no usable evidence"}

      true ->
        {:unknown, "Apply outcome unknown; no usable evidence"}
    end
  end

  # The strongest role with usable (settled or settling) evidence decides.
  defp tier(entries) do
    case Enum.max_by(entries, &rank/1, fn -> nil end) do
      %{role: role, state: state, input: input}
      when state in [:contradicted, :pending, :confirmed] ->
        label = role |> Atom.to_string() |> String.capitalize()

        case state do
          :contradicted -> {:mismatch, "#{label} evidence #{input} disagrees"}
          :pending -> {:pending, "Waiting for evidence"}
          :confirmed -> {:confirmed, "#{label} evidence agrees"}
        end

      _ ->
        nil
    end
  end

  defp rank(%{role: role, state: state}) do
    case @states[state] do
      nil -> {0, 0}
      priority -> {@tiers[role], priority}
    end
  end

  defp summary(nil), do: nil
  defp summary(%{outcome: {:failed, _}}), do: :failed
  defp summary(%{outcome: outcome}), do: outcome

  defp reason({:failed, reason}),
    do: inspect(reason, limit: 8, printable_limit: 80) |> String.slice(0, 120)
end

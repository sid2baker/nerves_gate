defmodule NervesGate.Network.Signals do
  @moduledoc """
  Best-effort facts scoped to a runtime incarnation. The private workflow
  reconciliation request re-reads live admission; it is not a public fact and
  does not advance the form revision. Neither kind is durable delivery.
  """
  def source(scope) do
    "/nerves_gate/network/#{scope}"
  end

  def new(type, id, phase, sequence, scope \\ "local") do
    Jido.Signal.new!(type, %{trial_id: id, phase: phase, sequence: sequence},
      source: source(scope)
    )
  end

  def schema do
    Zoi.object(%{
      trial_id: Zoi.string() |> Zoi.nullable(),
      phase: Zoi.enum([:idle, :applying, :pending, :confirming, :recovering]),
      sequence: Zoi.integer() |> Zoi.min(0)
    })
  end
end

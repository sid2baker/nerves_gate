defmodule NervesGate.Remote.Signals do
  @moduledoc """
  Best-effort, non-durable domain facts. Payload contains only operation_id
  (string or nil), phase (idle/running) and a runtime-scoped sequence integer.
  Duplicate/stale facts are harmless; subscribers reconcile from observations.
  Credentials, enrollment URLs and unfiltered daemon errors are never included.
  """
  def new(type, operation_id, phase, sequence, scope \\ "local") do
    Jido.Signal.new!(type, %{operation_id: operation_id, phase: phase, sequence: sequence},
      source: source(scope)
    )
  end

  def source(scope), do: "/nerves_gate/remote/#{scope}"
end

defmodule NervesGate.Network.Actions.Advance do
  @moduledoc "First-USB-setup policy, evaluated against live admission rather than queued facts."
  use Jido.Action, name: "network_advance", schema: Zoi.object(%{})
  alias NervesGate.Network.{Effect, Plugin, Policy}

  @impl true
  def run(_, context), do: advance(context.plugin_inputs[Plugin].runtime, context.agent_state)

  defp advance(%{phase: :pending, trial: %{auto_save: true} = trial} = status, state) do
    operation =
      cond do
        status.ready -> :auto_confirm
        Policy.conflicts(status.observed, trial.network) != [] -> :auto_cancel
        status.proposal_reply_pending -> :await
        true -> nil
      end

    if operation,
      do: {:ok, state, [%Effect{operation: operation, id: trial.id}]},
      else: {:ok, state}
  end

  defp advance(_, state), do: {:ok, state}
end

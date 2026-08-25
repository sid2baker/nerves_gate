defmodule NervesGate.FSM.Listener do
  @moduledoc """
  Performs the two post-transition duties shared by lifecycle protocols.

  The callback runs in the FSM process and must stay short: the owner publishes
  the already-computed projection and only enqueues supervised runtime work.
  """

  @behaviour Finitomata.Listener

  @impl true
  def after_transition(_name, state, %{owner: owner} = payload) when is_atom(owner) do
    if function_exported?(owner, :after_transition, 2),
      do: owner.after_transition(state, payload),
      else: :ok

    NervesGate.FSM.Diagnostics.deliver_reply(payload)
  end

  def after_transition(_name, _state, payload) do
    NervesGate.FSM.Diagnostics.deliver_reply(payload)
  end
end

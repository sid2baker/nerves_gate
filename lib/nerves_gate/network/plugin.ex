defmodule NervesGate.Network.Plugin do
  @moduledoc """
  Supplies fresh trial state to Jido and submits its automatic decisions.
  The sibling runtime owns hardware work, caller replies and the watchdog.
  """
  use Jido.Plugin
  alias NervesGate.Network

  @impl true
  def directives(_), do: [Network.Effect]

  @impl true
  def admit(nil, admission, _),
    do: {:ok, Network.Runtime.admission(Network.Runtime.via(admission.agent_id))}

  @impl true
  def dispatch(nil, effect, context, _) do
    # A decision can become stale after admission; the runtime veto is final.
    Network.Runtime.execute(Network.Runtime.via(context.agent_id), effect)
    :ok
  end
end

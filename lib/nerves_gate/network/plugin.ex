defmodule NervesGate.Network.Plugin do
  @moduledoc """
  Jido admission reads the trial runtime; post-commit directives submit effects
  without holding the agent turn open. The runtime acknowledges completion through
  a private reply alias. Handles are transient context, never agent state.
  The safety runtime is a sibling, not a child of the agent: its watchdog must
  survive an AgentServer failure.
  """
  use Jido.Plugin
  alias NervesGate.{Command, Network}

  @impl true
  def directives(_), do: [Network.Effect]

  @impl true
  def admit(nil, admission, _) do
    {:ok, Network.Runtime.admission(Network.Runtime.via(admission.agent_id))}
  end

  @impl true
  def dispatch(nil, effect, context, _) do
    case Network.Runtime.execute(
           Network.Runtime.via(context.agent_id),
           effect,
           context.turn_context
         ) do
      :pending -> :ok
      result -> Command.reply(context.turn_context, result)
    end
  end
end

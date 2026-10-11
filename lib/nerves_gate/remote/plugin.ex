defmodule NervesGate.Remote.Plugin do
  @moduledoc "Live daemon admission and post-commit effect dispatch; no daemon state in the agent."
  use Jido.Plugin
  alias NervesGate.{Command, Remote}

  @impl true
  def directives(_), do: [Remote.Effect]

  @impl true
  def admit(nil, admission, _) do
    {:ok, Remote.Runtime.status(Remote.Runtime.via(admission.agent_id))}
  end

  @impl true
  def dispatch(nil, effect, context, _) do
    result =
      Remote.Runtime.execute(Remote.Runtime.via(context.agent_id), effect, context.turn_context)

    Command.reply(context.turn_context, result)
  end
end

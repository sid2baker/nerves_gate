defmodule NervesGate.Remote.Actions.Disconnect do
  @moduledoc "Admit an explicit logout; no automatic recovery policy calls this Action."
  use Jido.Action,
    name: "remote_disconnect",
    schema: Zoi.object(%{params: Zoi.any(), id: Zoi.string()})

  @impl true
  def run(%{params: params, id: id}, context),
    do: NervesGate.Remote.Policy.request(:disconnect, params, id, context)
end

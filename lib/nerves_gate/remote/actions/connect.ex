defmodule NervesGate.Remote.Actions.Connect do
  @moduledoc "Validate and admit enrollment; request a bounded daemon effect after commit."
  use Jido.Action,
    name: "remote_connect",
    schema: Zoi.object(%{params: Zoi.any(), id: Zoi.string()})

  @impl true
  def run(%{params: params, id: id}, context),
    do: NervesGate.Remote.Policy.request(:connect, params, id, context)
end

defmodule NervesGate.Remote.Actions.Configure do
  @moduledoc "Admit a hostname patch, preserving all unrelated daemon preferences."
  use Jido.Action,
    name: "remote_configure",
    schema: Zoi.object(%{params: Zoi.any(), id: Zoi.string()})

  @impl true
  def run(%{params: params, id: id}, context),
    do: NervesGate.Remote.Policy.request(:configure, params, id, context)
end

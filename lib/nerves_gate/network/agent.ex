defmodule NervesGate.Network.Agent do
  @moduledoc "LAN trial policy. No saved settings, event history or duplicate lifecycle state."
  use Jido.Agent, name: "network"
  alias NervesGate.Network.{Actions, Plugin}

  agent do
    schema(Zoi.object(%{}))
    plugin(Plugin)
  end

  routes do
    route("network.reconcile", Actions.Advance)
  end
end

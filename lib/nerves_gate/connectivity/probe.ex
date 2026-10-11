defmodule NervesGate.Connectivity.Probe do
  @moduledoc "Read-only diagnostic reconciliation, run outside agent processing in a bounded worker."
  alias NervesGate.{Network, Observations, Remote}

  @callback read(atom(), atom()) :: map()

  def read(network, remote) do
    %{
      internet: Observations.Network.internet(Network.status(network)),
      remote_state: Remote.status(remote).state
    }
  end
end

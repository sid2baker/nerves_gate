defmodule NervesGate.Cluster.Supervisor do
  @moduledoc "Supervises the cluster owner and independent peer FSMs."

  use Supervisor

  alias NervesGate.Cluster
  alias NervesGate.Cluster.Peer.Supervisor, as: PeerSupervisor

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    children = [
      {Cluster, payload: Cluster.new(options), name: Cluster},
      PeerSupervisor
    ]

    # Peer infrastructure may restart without discarding the coordinator's
    # desired group. An owner restart also rebuilds the peer infrastructure.
    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule NervesGateWeb.DiscoveryController do
  @moduledoc "Tailnet-only public metadata used for gateway group discovery."

  use NervesGateWeb, :controller

  alias NervesGate.Cluster.Manager
  alias NervesGate.Identity

  def show(connection, _params) do
    identity = Identity.get()
    cluster = Manager.status()

    json(connection, %{
      gateway_id: identity.machine_id,
      hostname: identity.hostname,
      cluster_group: cluster.group
    })
  end
end

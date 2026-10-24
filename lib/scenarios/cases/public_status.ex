defmodule Scenarios.Cases.PublicStatus do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.Device, as: Device

  def spec do
    %{
      name: "Public status describes the device and is JSON encodable",
      requires: %{device: [], fixture: []}
    }
  end

  def run(%{device: device}) do
    status = Device.status(device)
    assert status.device.available
    assert status.system.node == device.node
    assert is_binary(status.system.target) and status.system.target != ""
    assert map_size(status.actions) > 0
    assert is_boolean(status.cellular.supported)
    assert is_boolean(status.capabilities.ethernet)
    assert {:ok, _} = Jason.encode(status)

    # The workstation and the device derive exactly the same public read model.
    projection = GenServer.call({NervesGate.ProjectionServer, device.node}, :snapshot)
    assert projection.status.system == status.system

    for key <- [:ethernet, :mobile, :failover],
        do: assert(projection.status.capabilities[key] == status.capabilities[key])
  end
end

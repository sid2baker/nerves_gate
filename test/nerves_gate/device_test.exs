defmodule NervesGate.DeviceTest do
  use ExUnit.Case, async: true

  alias NervesGate.Device
  alias NervesGate.Store
  alias NervesGate.TestScenario

  test "device name and editor history are readable JSON under data" do
    root = TestScenario.temporary_root(:device)
    :ok = Store.initialize(root)
    name = String.to_atom("device_#{System.unique_integer([:positive])}")
    {:ok, device} = Device.start_link(name: name, root: root)

    assert :ok = Device.rename("Pump room gateway", %{name: "Ada", ip: "100.64.0.20"}, device)

    profile = Device.get(device)
    assert profile["name"] == "Pump room gateway"
    assert profile["revision"] == 1
    assert profile["updated_by"] == %{"name" => "Ada", "ip" => "100.64.0.20"}
    assert [%{"field" => "name", "from" => _, "to" => "Pump room gateway"}] = profile["history"]

    persisted = File.read!(Path.join(root, "device.json"))
    assert persisted =~ "\n  \"history\""
    assert Jason.decode!(persisted) == profile
  end
end

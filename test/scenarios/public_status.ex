defmodule NervesGate.Scenarios.PublicStatus do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "Public status describes the QEMU device and is JSON encodable"

  def run(vm) do
    status = Qemu.status(vm)
    assert status.system.target == "x86_64"
    assert status.system.node == :"nerves_gate@192.168.77.2"
    assert status.backend.available
    assert map_size(status.actions) > 0
    assert {:ok, _} = Jason.encode(status)
  end
end

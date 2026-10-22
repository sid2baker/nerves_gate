defmodule Dev.DevicesTest do
  use ExUnit.Case, async: true

  test "only owned inventory is simulated, regardless of advertised kind, name or target" do
    {:ok, gateway} = Dev.Discovery.manual("ec100.example.ts.net")
    gateway = Map.merge(gateway, %{name: "gateway_a", target: "x86_64", kind: :simulated})
    devices = Dev.Devices.list(bench(), %{devices: [gateway]})
    assert [physical] = Enum.filter(devices, &(&1.kind == :physical))
    assert physical.path == "/devices/physical/ec100.example.ts.net"
    assert physical.status == "Unverified"
    assert [simulated] = Enum.filter(devices, &(&1.kind == :simulated))
    assert simulated.path == "/devices/gateway_a"
    assert simulated.status == "Stopped"
    assert simulated.version == nil
    assert simulated.url == nil
  end

  test "type and case-insensitive search filters compose" do
    {:ok, gateway} = Dev.Discovery.manual("ec100.example.ts.net")
    devices = Dev.Devices.list(bench(), %{devices: [gateway]})
    assert [%{kind: :simulated}] = Dev.Devices.filter(devices, "simulated", " GATEWAY ")
    assert [%{kind: :physical}] = Dev.Devices.filter(devices, "all", "EXAMPLE.TS.NET")
    assert Dev.Devices.filter(devices, "physical", "gateway_a") == []
    assert length(Dev.Devices.filter(devices, "all", "")) == 2
  end

  defp bench do
    %{
      lifecycle: %{status: :stopped, devices: [%{id: :gateway_a, address: "127.0.0.2"}]},
      devices: %{}
    }
  end
end

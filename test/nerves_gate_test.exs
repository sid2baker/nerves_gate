defmodule NervesGateTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.State

  test "connects clients to complete live state behind a thin command boundary" do
    assert {:ok, %NervesGate.Client{} = client, %{local: %{state: %State{}}, replicas: replicas}} =
             NervesGate.connect()

    assert is_map(replicas)
    assert is_boolean(NervesGate.configured?(client))
    assert NervesGate.state(client).local.state.__struct__ == State

    assert %{schema: "nerves_gate.status.v3", local: %{state: state}} =
             NervesGate.status(client)

    assert is_map(state)
    assert :ok = NervesGate.disconnect(client)
  end

  test "web code does not reach through the backend boundary" do
    forbidden =
      ~r/NervesGate\.(Alarms|Backend|Client|Cluster|Commissioning|DeviceState|Firmware|Fleet|FSM|Gateway|Identity|Internet|Reconciliation|SSH|Storage|SubnetRouter|Tailnet)/

    violations =
      "lib/nerves_gate_web/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ forbidden))

    assert violations == []
  end
end

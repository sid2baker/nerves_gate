defmodule NervesGateTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.State

  test "is the typed public Command/Event/State boundary" do
    assert %{state: %State{}} = NervesGate.snapshot()
    assert %{local: %{state: %State{}}, replicas: replicas} = NervesGate.fleet()
    assert is_map(replicas)
    assert is_boolean(NervesGate.configured?())

    assert %{schema: "nerves_gate.status.v3", local: %{state: state}} = NervesGate.status()
    assert is_map(state)
  end

  test "web code does not reach through the backend boundary" do
    forbidden =
      ~r/NervesGate\.(Alarms|Backend|Cluster|Commissioning|DeviceState|FSM|Gateway|Identity|Internet|SSH|Storage|SubnetRouter|Tailnet)/

    violations =
      "lib/nerves_gate_web/**/*.ex"
      |> Path.wildcard()
      |> Enum.filter(&(File.read!(&1) =~ forbidden))

    assert violations == []
  end
end

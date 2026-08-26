defmodule NervesGateTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.State

  test "connects clients to complete live state behind a thin command boundary" do
    assert {:ok, session, %{local: %{state: %State{}}, replicas: replicas}} =
             NervesGate.connect()

    assert is_pid(session)
    assert is_map(replicas)
    assert is_boolean(NervesGate.configured?(session))
    assert NervesGate.state(session).local.state.__struct__ == State

    assert %{schema: "nerves_gate.status.v3", local: %{state: state}} =
             NervesGate.status(session)

    assert is_map(state)
    assert :ok = NervesGate.disconnect(session)
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

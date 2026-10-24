defmodule NervesGate.SDKOwnershipTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Buses, SDKBackend}

  setup do
    start_supervised!({PropertyTable, name: NervesGate.Properties})
    buses = start_supervised!(Buses)
    :erlang.trace(buses, true, [:receive])
    %{buses: buses}
  end

  test "SDK bus subscriptions and claims reach the owner from the actual caller", %{buses: buses} do
    caller = self()

    for {operation, args} <- [can_subscribe: ["can0"], rs485_claim: ["rs485_1"]] do
      # Real host services have no bus hardware. Rejection still exercises the
      # full SDK-to-owner call path, without introducing fake devices or UARTs.
      assert {:error, :bus_unsupported} = SDKBackend.call(operation, args)

      assert_receive {:trace, ^buses, :receive,
                      {:"$gen_call", {^caller, _}, {:sdk, ^operation, ^args}}}
    end

    state = :sys.get_state(buses)
    assert state.claims == %{}
    assert state.subscribers == %{}
    assert state.monitors == %{}
  end
end

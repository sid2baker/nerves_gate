defmodule NervesGate.SDKOwnershipTest do
  use ExUnit.Case, async: false
  alias NervesGate.{Buses, SDKBackend}

  setup do
    start_supervised!({PropertyTable, name: NervesGate.Properties})
    buses = start_supervised!(Buses)
    :erlang.trace(buses, true, [:receive])
    %{buses: buses}
  end

  test "configuration rejects active CAN subscribers before any hardware effect" do
    state = %{claims: %{}, subscribers: %{"can0" => MapSet.new([self()])}}

    assert {:reply, {:error, %{code: "port_in_use"}}, ^state} =
             Buses.handle_call(
               {:configure, "can0", %{"enabled" => "true", "bitrate" => "125000"}},
               {self(), make_ref()},
               state
             )
  end

  test "public hardware usage contains only ownership flags and subscription counts" do
    state = %{
      adapter: nil,
      ports: [%{name: "ttyS3"}, %{name: "can0"}],
      claims: %{make_ref() => %{name: "ttyS3", pid: self(), uart: self()}},
      subscribers: %{"can0" => MapSet.new([self()])},
      operation: nil,
      result: nil,
      error: nil
    }

    assert {:reply, status, ^state} = Buses.handle_call(:status, nil, state)

    assert status.ports == [
             %{name: "ttyS3", claimed: true, subscribers: 0},
             %{name: "can0", claimed: false, subscribers: 1}
           ]

    refute inspect(status) =~ "#PID"
    refute inspect(status) =~ "#Reference"
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

defmodule IotrouterExpansion.LifecycleTest do
  use ExUnit.Case, async: true
  alias IotrouterExpansion.{Bus, Outputs, Protocol}

  test "loss of cyclic data stops instead of refreshing old readings or reconnecting" do
    state = %{last_frame: System.monotonic_time(:millisecond) - 5_000}
    assert {:stop, :cyclic_data_lost, ^state} = Bus.handle_info(:refresh, state)
  end

  test "a dead bus latches cleanup until checked whole-plugin restart" do
    ref = make_ref()
    initial = %{monitor: ref, error: nil}

    assert {:noreply, failed} =
             IotrouterExpansion.handle_info({:DOWN, ref, :process, self(), :killed}, initial)

    assert failed.monitor == nil

    assert {:reply, {:error, :restart_plugin_to_verify_cleanup}, ^failed} =
             IotrouterExpansion.handle_call(:start, nil, failed)

    assert {:reply, {:error, :restart_plugin_to_verify_cleanup}, ^failed} =
             IotrouterExpansion.handle_call(:stop, nil, failed)
  end

  test "writes reject stale echoes and concurrent setters without opening a transport" do
    state = %{
      echo: %{2 => List.duplicate(false, 16)},
      pending: nil,
      last_frame: System.monotonic_time(:millisecond) - 5_000
    }

    assert {:reply, {:error, :cyclic_data_stale}, ^state} =
             Bus.handle_call({:write, 2, 0, true}, nil, state)

    busy = %{state | pending: :existing_setter}

    assert {:reply, {:error, :write_in_progress}, ^busy} =
             Bus.handle_call({:write, 2, 0, true}, nil, busy)

    fresh = %{state | last_frame: System.monotonic_time(:millisecond)}
    assert {:reply, :ok, ^fresh} = Bus.handle_call({:write, 2, 0, false}, nil, fresh)

    assert {:reply, {:error, :invalid_channel_value}, ^fresh} =
             Bus.handle_call({:write, 2, 16, true}, nil, fresh)
  end

  test "expired setters are dropped as unknown, never retained in a future card target" do
    ref = make_ref()
    pending = %{from: {self(), ref}, until: System.monotonic_time(:millisecond) - 1}
    state = %{cards: [:card], buffer: <<>>, pending: pending}
    assert {:noreply, %{pending: nil}} = Bus.handle_info({:circuits_uart, :unused, <<>>}, state)
    assert_receive {^ref, {:error, :not_confirmed}}
  end

  test "release performs no implicit write, and unsupported digital encodings fail closed" do
    channels = %{"card2_d0016n.do0" => {2, 0}}
    assert {:applied, ^channels} = Outputs.apply("card2_d0016n.do0", nil, channels)

    assert_raise ArgumentError, "Unsupported digital channel encoding", fn ->
      Protocol.channels(<<2, 0::size(31)-unit(8)>>, 16)
    end
  end
end

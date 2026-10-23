defmodule NervesGate.Network.CellularPINTest do
  use ExUnit.Case, async: true
  alias NervesGate.Network.CellularPIN

  @identity "89880000000000000001"
  @other_sim "89880000000000000002"
  @pin "4812"

  setup do
    table = :"cellular_pin_#{System.unique_integer([:positive])}"
    dir = Path.join(System.tmp_dir!(), Atom.to_string(table))
    on_exit(fn -> File.rm_rf!(dir) end)
    start = fn -> start_supervised!({PropertyTable, name: table, persist_data_path: dir}) end
    start.()
    %{table: table, dir: dir, start: start}
  end

  test "nothing saved is off", %{table: table} do
    assert CellularPIN.metadata(nil, table) == %{pin_saved: false, auto_unlock: :off}
    assert CellularPIN.forget(table) == :ok
    assert CellularPIN.block(table) == :ok
    assert CellularPIN.consume(@identity, table) == {:error, :cellular_pin_not_saved}
  end

  test "saved PIN survives a restart without the raw SIM identity", context do
    assert CellularPIN.save(@pin, @identity, context.table) == :ok
    refute File.read!(Path.join([context.dir, "#{context.table}", "data.ptable"])) =~ @identity

    restart(context)

    assert CellularPIN.metadata(@identity, context.table) == %{
             pin_saved: true,
             auto_unlock: :ready
           }

    assert CellularPIN.metadata(nil, context.table) ==
             %{pin_saved: true, auto_unlock: :identity_unknown}
  end

  test "an automatic attempt stays blocked across restarts until a known success", context do
    %{table: table} = context
    assert CellularPIN.save(@pin, @identity, table) == :ok
    assert CellularPIN.consume(@identity, table) == {:ok, @pin}

    restart(context)
    assert CellularPIN.metadata(@identity, table).auto_unlock == :blocked
    assert CellularPIN.consume(@identity, table) == {:error, :cellular_auto_unlock_blocked}

    assert CellularPIN.save(@pin, @identity, table) == :ok
    assert CellularPIN.metadata(@identity, table).auto_unlock == :ready
  end

  test "the PIN is never sent to another or unidentified SIM", %{table: table} do
    assert CellularPIN.save(@pin, @identity, table) == :ok
    assert CellularPIN.metadata(@other_sim, table).auto_unlock == :different_sim

    for identity <- [@other_sim, nil, "not-an-iccid"] do
      assert CellularPIN.consume(identity, table) == {:error, :cellular_auto_unlock_blocked}
    end

    assert CellularPIN.metadata(@identity, table).auto_unlock == :ready
  end

  test "forget removes the PIN across restarts", context do
    assert CellularPIN.save(@pin, @identity, context.table) == :ok
    assert CellularPIN.forget(context.table) == :ok

    restart(context)

    assert CellularPIN.metadata(@identity, context.table) == %{
             pin_saved: false,
             auto_unlock: :off
           }
  end

  test "invalid PINs and identities are refused", %{table: table} do
    for pin <- ["123", "123456789", "12a4", 1234] do
      assert CellularPIN.save(pin, @identity, table) == {:error, :cellular_pin_storage}
    end

    assert CellularPIN.save(@pin, "not-an-iccid", table) == {:error, :cellular_pin_storage}
    assert CellularPIN.metadata(nil, table).pin_saved == false
  end

  defp restart(%{table: table, start: start}) do
    :ok = stop_supervised(table)
    start.()
  end
end

defmodule NervesGate.Cellular.SIMTest do
  use ExUnit.Case, async: true
  alias NervesGate.Cellular.SIM

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
    assert SIM.metadata(nil, table) == %{pin_saved: false, auto_unlock: :off}
    assert SIM.forget(table) == :ok
    assert SIM.block(table) == :ok

    assert SIM.consume(@identity, table) ==
             {:error,
              %{code: "cellular_pin_not_saved", message: "No SIM PIN is saved on this device."}}
  end

  test "saved PIN survives a restart without the raw SIM identity", context do
    assert SIM.save(@pin, @identity, context.table) == :ok
    refute File.read!(Path.join([context.dir, "#{context.table}", "data.ptable"])) =~ @identity

    restart(context)

    assert SIM.metadata(@identity, context.table) == %{
             pin_saved: true,
             auto_unlock: :ready
           }

    assert SIM.metadata(nil, context.table) ==
             %{pin_saved: true, auto_unlock: :identity_unknown}
  end

  test "an automatic attempt stays blocked across restarts until a known success", context do
    %{table: table} = context
    assert SIM.save(@pin, @identity, table) == :ok
    assert SIM.consume(@identity, table) == {:ok, @pin}

    restart(context)
    assert SIM.metadata(@identity, table).auto_unlock == :blocked

    assert SIM.consume(@identity, table) ==
             {:error,
              %{
                code: "cellular_auto_unlock_blocked",
                message:
                  "Automatic unlock is blocked or the SIM identity could not be matched. Verify the SIM and explicitly unlock or save its PIN; no automatic retry was sent."
              }}

    assert SIM.save(@pin, @identity, table) == :ok
    assert SIM.metadata(@identity, table).auto_unlock == :ready
  end

  test "the PIN is never sent to another or unidentified SIM", %{table: table} do
    assert SIM.save(@pin, @identity, table) == :ok
    assert SIM.metadata(@other_sim, table).auto_unlock == :different_sim

    for identity <- [@other_sim, nil, "not-an-iccid"] do
      assert SIM.consume(identity, table) ==
               {:error,
                %{
                  code: "cellular_auto_unlock_blocked",
                  message:
                    "Automatic unlock is blocked or the SIM identity could not be matched. Verify the SIM and explicitly unlock or save its PIN; no automatic retry was sent."
                }}
    end

    assert SIM.metadata(@identity, table).auto_unlock == :ready
  end

  test "forget removes the PIN across restarts", context do
    assert SIM.save(@pin, @identity, context.table) == :ok
    assert SIM.forget(context.table) == :ok

    restart(context)

    assert SIM.metadata(@identity, context.table) == %{
             pin_saved: false,
             auto_unlock: :off
           }
  end

  test "invalid PINs and identities are refused", %{table: table} do
    for pin <- ["123", "123456789", "12a4", 1234] do
      assert SIM.save(pin, @identity, table) ==
               {:error,
                %{
                  code: "cellular_pin_storage",
                  message:
                    "The SIM PIN could not be saved. The SIM operation may already have succeeded; read status rather than resending it. Automatic unlock sends no PIN unless its safety latch is persisted first."
                }}
    end

    assert SIM.save(@pin, "not-an-iccid", table) ==
             {:error,
              %{
                code: "cellular_pin_storage",
                message:
                  "The SIM PIN could not be saved. The SIM operation may already have succeeded; read status rather than resending it. Automatic unlock sends no PIN unless its safety latch is persisted first."
              }}

    assert SIM.metadata(nil, table).pin_saved == false
  end

  defp restart(%{table: table, start: start}) do
    :ok = stop_supervised(table)
    start.()
  end
end

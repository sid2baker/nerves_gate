defmodule NervesGate.Network.TrialStoreTest do
  use ExUnit.Case, async: true

  alias NervesGate.{AtomicFile, Config}
  alias NervesGate.Network.{Host, Recovery, Trial, TrialStore}

  @moduletag :tmp_dir
  @network %{"mode" => "shared", "equipment" => %{"ip_method" => "dhcp"}}

  defmodule Storage do
    @behaviour AtomicFile
    def read(path), do: AtomicFile.read(path)

    def write(path, contents) do
      case Process.get(:storage_write_fault, fn _, _ -> nil end).(path, contents) do
        :before ->
          {:error, {:not_committed, :enospc}}

        :after ->
          :ok = AtomicFile.write(path, contents)
          {:error, {:uncertain, :eio}}

        nil ->
          AtomicFile.write(path, contents)
      end
    end

    def remove(path) do
      if Process.get(:storage_remove_fault), do: {:error, :eacces}, else: AtomicFile.remove(path)
    end
  end

  defmodule Unavailable do
    @behaviour NervesGate.Network.Adapter
    def apply_config(_, _), do: {:error, :unavailable}
    def snapshot(_), do: nil
  end

  setup %{tmp_dir: dir} do
    path = Path.join(dir, "config.json")
    host = start_supervised!({Host, name: nil})
    {:ok, network} = Config.validate_network(@network)
    record = Trial.new(Config.defaults(), network, false, 60_000)
    %{path: path, host: host, adapter: {Host, host}, record: record}
  end

  test "both previous settings and the pending decision precede hardware writes", ctx do
    assert :ok = TrialStore.prepare(ctx.record, ctx.path)
    assert {:ok, saved} = Config.load(ctx.path)
    assert saved == Config.defaults()
    assert {:ok, record} = TrialStore.load(ctx.path)
    assert record == ctx.record
    assert record["phase"] == "pending"
    assert Bitwise.band(File.stat!(ctx.path).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(TrialStore.path(ctx.path)).mode, 0o777) == 0o600
  end

  test "crash after writing requested config but before decision rolls back", ctx do
    :ok = TrialStore.prepare(ctx.record, ctx.path)
    :ok = Config.save(ctx.record["requested"], ctx.path)
    :ok = Host.apply_config(ctx.record["requested"]["network"], ctx.host)
    assert Host.snapshot(ctx.host).bridge.method == "dhcp"

    assert {:ok, previous} = Recovery.restore(ctx.path, ctx.adapter)
    assert previous == ctx.record["previous"]
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
    assert {:ok, ^previous} = Config.load(ctx.path)
    assert {:ok, nil} = TrialStore.load(ctx.path)
    assert {:ok, ^previous} = Recovery.restore(ctx.path, ctx.adapter)
  end

  test "confirmed journal finishes the new commit after crash, even with old config file", ctx do
    :ok = TrialStore.prepare(ctx.record, ctx.path)
    assert {:ok, confirmed} = TrialStore.confirm(ctx.record, ctx.path)
    assert confirmed["phase"] == "confirmed"
    :ok = Config.save(ctx.record["previous"], ctx.path)

    assert {:ok, requested} = Recovery.restore(ctx.path, ctx.adapter)
    assert requested == ctx.record["requested"]
    assert Host.snapshot(ctx.host).bridge.method == "dhcp"
    assert {:ok, ^requested} = Config.load(ctx.path)
    assert {:ok, nil} = TrialStore.load(ctx.path)
    assert {:ok, ^requested} = Recovery.restore(ctx.path, ctx.adapter)
  end

  test "failed config replacement has a rollback outcome and no confirmed decision", ctx do
    :ok = TrialStore.prepare(ctx.record, ctx.path)
    Process.put(:storage_write_fault, fn path, _ -> if path == ctx.path, do: :before end)

    assert {:error, {:save, {:not_committed, :enospc}}, :rollback} =
             TrialStore.confirm(ctx.record, ctx.path, Storage)

    assert {:ok, %{"phase" => "pending"}} = TrialStore.load(ctx.path)
    Process.delete(:storage_write_fault)
    assert {:ok, _} = Recovery.restore(ctx.path, ctx.adapter)
  end

  test "uncertain config write is still unconfirmed and safe to roll back", ctx do
    :ok = TrialStore.prepare(ctx.record, ctx.path)
    Process.put(:storage_write_fault, fn path, _ -> if path == ctx.path, do: :after end)

    assert {:error, {:save, {:uncertain, :eio}}, :rollback} =
             TrialStore.confirm(ctx.record, ctx.path, Storage)

    assert {:ok, %{"phase" => "pending"}} = TrialStore.load(ctx.path)
    Process.delete(:storage_write_fault)
    assert {:ok, previous} = Recovery.restore(ctx.path, ctx.adapter)
    assert previous == ctx.record["previous"]
  end

  test "failed confirmed marker rolls back; uncertain marker reconciles, never blindly undoes",
       ctx do
    :ok = TrialStore.prepare(ctx.record, ctx.path)

    Process.put(:storage_write_fault, fn path, _ ->
      if path == TrialStore.path(ctx.path), do: :before
    end)

    assert {:error, {:save, {:not_committed, :enospc}}, :rollback} =
             TrialStore.confirm(ctx.record, ctx.path, Storage)

    assert {:ok, %{"phase" => "pending"}} = TrialStore.load(ctx.path)

    Process.put(:storage_write_fault, fn path, _ ->
      if path == TrialStore.path(ctx.path), do: :after
    end)

    assert {:error, :outcome_unknown, :reconcile} =
             TrialStore.confirm(ctx.record, ctx.path, Storage)

    Process.delete(:storage_write_fault)
    assert {:ok, requested} = Recovery.restore(ctx.path, ctx.adapter)
    assert requested == ctx.record["requested"]
  end

  test "rollback keeps its journal through hardware failure and retries idempotently", ctx do
    :ok = TrialStore.prepare(ctx.record, ctx.path)
    assert {:error, {:restore, :unavailable}} = Recovery.restore(ctx.path, {Unavailable, nil})
    assert {:ok, %{"phase" => "pending"}} = TrialStore.load(ctx.path)
    assert {:ok, _} = Recovery.restore(ctx.path, ctx.adapter)
    assert {:ok, nil} = TrialStore.load(ctx.path)
  end

  test "rollback restores hardware despite disk failure and retains recovery authority", ctx do
    :ok = TrialStore.prepare(ctx.record, ctx.path)
    :ok = Host.apply_config(ctx.record["requested"]["network"], ctx.host)
    Process.put(:storage_write_fault, fn _, _ -> :before end)
    assert {:error, {:restore, _}} = Recovery.restore(ctx.path, ctx.adapter, Storage)
    assert Host.snapshot(ctx.host).bridge.method == "disabled"
    assert {:ok, %{"phase" => "pending"}} = TrialStore.load(ctx.path)
    Process.delete(:storage_write_fault)
    assert {:ok, _} = Recovery.restore(ctx.path, ctx.adapter, Storage)
  end

  test "cleanup failure cannot erase or reverse a confirmed decision", ctx do
    :ok = TrialStore.prepare(ctx.record, ctx.path)
    {:ok, _} = TrialStore.confirm(ctx.record, ctx.path)
    Process.put(:storage_remove_fault, true)
    assert {:error, {:restore, :eacces}} = Recovery.restore(ctx.path, ctx.adapter, Storage)
    assert {:ok, %{"phase" => "confirmed"}} = TrialStore.load(ctx.path)
    Process.delete(:storage_remove_fault)
    assert {:ok, requested} = Recovery.restore(ctx.path, ctx.adapter, Storage)
    assert requested == ctx.record["requested"]
  end

  test "corrupt journal fails closed and is never silently overwritten", ctx do
    File.write!(TrialStore.path(ctx.path), "broken")
    assert {:error, {:load, _}} = Recovery.restore(ctx.path, ctx.adapter)
    assert {:error, _} = TrialStore.prepare(ctx.record, ctx.path)
    assert File.read!(TrialStore.path(ctx.path)) == "broken"
  end

  test "a second preparation never overwrites an unfinished recovery decision", ctx do
    :ok = TrialStore.prepare(ctx.record, ctx.path)
    newer = %{ctx.record | "id" => String.duplicate("x", 32)}
    assert {:error, :recovery_in_progress} = TrialStore.prepare(newer, ctx.path)
    assert {:ok, record} = TrialStore.load(ctx.path)
    assert record == ctx.record
  end

  test "expired wall-clock metadata never authorizes pending settings after reboot", ctx do
    record = %{ctx.record | "expires_at" => 0}
    :ok = TrialStore.prepare(record, ctx.path)
    assert {:ok, previous} = Recovery.restore(ctx.path, ctx.adapter)
    assert previous == record["previous"]
  end
end

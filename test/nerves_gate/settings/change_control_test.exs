defmodule NervesGate.Settings.ChangeControlTest do
  use ExUnit.Case

  alias NervesGate.Settings.ChangeControl
  alias NervesGate.Settings.Maintenance
  alias NervesGate.Store
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:change_control)
    :ok = Store.initialize(root)

    on_exit(fn ->
      Maintenance.clear()
      File.rm_rf!(root)
    end)

    %{root: root}
  end

  test "one persisted change lock exposes maintenance scope and fresh-connection confirmation", %{
    root: root
  } do
    control = start_control(root)

    assert :ok =
             ChangeControl.begin_change(
               :internet,
               "change-1",
               self(),
               "connection-a",
               %{},
               control
             )

    assert Maintenance.layers() == [:internet, :tailnet, :cluster]

    assert {:error, :settings_change_in_progress} =
             ChangeControl.begin_change(
               :cluster,
               "change-2",
               self(),
               "connection-a",
               %{},
               control
             )

    assert :ok = ChangeControl.awaiting_confirmation("change-1", %{}, 1_000, control)
    refute ChangeControl.status("connection-a", control).pending.confirmable
    assert ChangeControl.status("connection-b", control).pending.confirmable
    assert {:ok, journal} = Store.read_settings_change(root)
    assert journal["kind"] == "internet"

    assert :ok = ChangeControl.finish("change-1", nil, control)
    assert Maintenance.layers() == []
    assert {:ok, nil} = Store.read_settings_change(root)
  end

  test "an owner crash retains the journal for subsystem rollback", %{root: root} do
    control = start_control(root)
    owner = spawn(fn -> Process.sleep(:infinity) end)

    assert :ok =
             ChangeControl.begin_change(
               :tailnet,
               "change-1",
               owner,
               "connection-a",
               %{"previous_profile_id" => "old-profile"},
               control
             )

    Process.exit(owner, :kill)

    assert_eventually(fn -> ChangeControl.active(nil, control).phase == :rolling_back end)
    assert {:ok, journal} = Store.read_settings_change(root)
    assert journal["phase"] == "rolling_back"
    assert Maintenance.layers() == [:tailnet, :cluster]
  end

  test "startup restores an interrupted change as rolling back", %{root: root} do
    assert :ok =
             Store.write_settings_change(
               %{
                 "version" => 1,
                 "id" => "interrupted",
                 "kind" => "cluster",
                 "phase" => "awaiting_confirmation",
                 "rollback" => %{},
                 "started_at" => DateTime.utc_now() |> DateTime.to_iso8601()
               },
               root
             )

    control = start_control(root)
    assert ChangeControl.active(nil, control).phase == :rolling_back
    assert ChangeControl.status(nil, control).pending.kind == :cluster
    assert Maintenance.layers() == [:cluster]
  end

  defp start_control(root) do
    name = String.to_atom("change_control_#{System.unique_integer([:positive])}")
    {:ok, control} = ChangeControl.start_link(name: name, root: root)
    on_exit(fn -> if Process.alive?(control), do: GenServer.stop(control) end)
    control
  end

  defp assert_eventually(predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not converge")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end
end

defmodule Scenarios.Cases.Concurrent do
  @moduledoc false
  import ExUnit.Assertions
  import Scenarios.Device

  def spec,
    do: %{
      :name => "simultaneous confirmations admit a trial only once",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    desired = settings("eth0")
    before = Scenarios.Device.status(vm).network.desired

    assert {:ok, trial} =
             Scenarios.Device.rpc(vm, NervesGate.Network, :propose, [desired, [expected: before]])

    Scenarios.Device.await(
      vm,
      "configuration ready to save",
      & &1.actions["network.confirm"].enabled
    )

    owner = self()

    callers =
      for _ <- 1..2 do
        Task.async(fn ->
          send(owner, {:ready, self()})

          receive do
            :confirm -> Scenarios.Device.rpc(vm, NervesGate.Network, :confirm, [trial])
          after
            5_000 -> flunk("Confirmation start barrier timed out")
          end
        end)
      end

    for task <- callers do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5_000
    end

    for task <- callers, do: send(task.pid, :confirm)
    results = Enum.map(callers, &Task.await(&1, 20_000))
    assert Enum.count(results, &(&1 == :ok)) == 1
    assert [{:error, %{code: code}}] = Enum.reject(results, &(&1 == :ok))
    assert code in ["recovery_in_progress", "no_matching_trial"]

    Scenarios.Device.await(vm, "one confirmation completed", fn status ->
      status.network.setup_completed && status.network.pending == nil &&
        status.network.desired == desired && not status.network.recovering
    end)

    assert {:error, %{code: "no_matching_trial"}} =
             Scenarios.Device.rpc(vm, NervesGate.Network, :confirm, [trial])
  end
end

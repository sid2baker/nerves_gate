defmodule Workbench.SessionServicesTest do
  use ExUnit.Case, async: false

  test "the explicit session owns its services without starting firmware or devices" do
    refute firmware_started?()
    refute Process.whereis(NervesGate.Supervisor)
    refute Process.whereis(Workbench.SessionServices)
    refute Process.whereis(WorkbenchWeb.Endpoint)

    endpoint = Application.fetch_env!(:nerves_gate_workbench, WorkbenchWeb.Endpoint)

    on_exit(fn ->
      Application.put_env(:nerves_gate_workbench, WorkbenchWeb.Endpoint, endpoint)
    end)

    # The real lifecycle owner starts empty. No QEMU process or network is created.
    start_supervised!({Simulator, %{devices: %{}}})

    Application.put_env(
      :nerves_gate_workbench,
      WorkbenchWeb.Endpoint,
      Keyword.put(endpoint, :server, false)
    )

    supervisor = start_supervised!({Workbench.SessionServices, poll: false})

    assert {:ok, {flags, children}} = Workbench.SessionServices.init(poll: false)
    assert flags.strategy == :rest_for_one

    assert Enum.map(children, & &1.id) == [
             Phoenix.PubSub.Supervisor,
             Workbench.Gateways,
             Scenarios.Runner,
             Workbench.Jobs,
             WorkbenchWeb.Endpoint
           ]

    processes =
      for {_, pid, _, _} <- Supervisor.which_children(supervisor) do
        assert is_pid(pid) and Process.alive?(pid)
        {pid, Process.monitor(pid)}
      end

    assert Process.whereis(NervesGate.PubSub)
    assert Process.whereis(Scenarios.Runner)
    assert Process.whereis(WorkbenchWeb.Endpoint)
    assert WorkbenchWeb.Endpoint.config(:server) == false
    assert Scenarios.Runner.snapshot().lifecycle.status == :stopped
    assert Simulator.devices() == %{}
    assert :ok = Scenarios.Runner.subscribe()
    assert :ok = Scenarios.Runner.unsubscribe()
    refute firmware_started?()
    refute Process.whereis(NervesGate.Supervisor)
    refute Process.whereis(NervesGateWeb.Endpoint)

    # Loss of an admission owner must not make an uncertain write replayable.
    # These are the real host services with an empty simulator, not a fake backend.
    :ok = Supervisor.terminate_child(supervisor, Workbench.Jobs)
    assert {:ok, _} = Supervisor.restart_child(supervisor, Workbench.Jobs)
    assert %{status: :uncertain, certainty: :unknown} = Workbench.Jobs.snapshot()
    :ok = Supervisor.terminate_child(supervisor, Scenarios.Runner)
    assert {:ok, _} = Supervisor.restart_child(supervisor, Scenarios.Runner)
    assert Scenarios.Runner.snapshot().blocked
    assert Simulator.devices() == %{}

    :ok = stop_supervised(Workbench.SessionServices)
    for {pid, ref} <- processes, do: assert_receive({:DOWN, ^ref, :process, ^pid, _})
    refute Process.whereis(NervesGate.PubSub)
    refute Process.whereis(Scenarios.Runner)
    refute Process.whereis(WorkbenchWeb.Endpoint)
    assert Process.whereis(Simulator)
    assert Simulator.devices() == %{}
    refute firmware_started?()
  end

  defp firmware_started?,
    do: Enum.any?(Application.started_applications(), &(elem(&1, 0) == :nerves_gate))
end

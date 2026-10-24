defmodule Dev.SessionServicesTest do
  use ExUnit.Case, async: false

  test "the explicit session owns its services without starting firmware or devices" do
    refute firmware_started?()
    refute Process.whereis(NervesGate.Supervisor)
    refute Process.whereis(Dev.SessionServices)
    refute Process.whereis(DevWeb.Endpoint)

    previous = Application.fetch_env(:nerves_gate, :simulator_node)
    endpoint = Application.fetch_env!(:nerves_gate_dev, DevWeb.Endpoint)

    on_exit(fn ->
      case previous do
        {:ok, node} -> Application.put_env(:nerves_gate, :simulator_node, node)
        :error -> Application.delete_env(:nerves_gate, :simulator_node)
      end

      Application.put_env(:nerves_gate_dev, DevWeb.Endpoint, endpoint)
    end)

    # The real lifecycle owner starts empty. No QEMU process or network is created.
    start_supervised!({Simulator, %{devices: %{}}})
    Application.put_env(:nerves_gate, :simulator_node, node())
    Application.put_env(:nerves_gate_dev, DevWeb.Endpoint, Keyword.put(endpoint, :server, false))
    supervisor = start_supervised!(Dev.SessionServices)

    assert {:ok, {flags, children}} = Dev.SessionServices.init([])
    assert flags.strategy == :rest_for_one

    assert Enum.map(children, & &1.id) == [
             Phoenix.PubSub.Supervisor,
             Simulator.QemuTests,
             DevWeb.Endpoint
           ]

    processes =
      for {_, pid, _, _} <- Supervisor.which_children(supervisor) do
        assert is_pid(pid) and Process.alive?(pid)
        {pid, Process.monitor(pid)}
      end

    assert Process.whereis(NervesGate.PubSub)
    assert Process.whereis(Simulator.QemuTests)
    assert Process.whereis(DevWeb.Endpoint)
    assert DevWeb.Endpoint.config(:server) == false
    assert Simulator.QemuTests.snapshot().lifecycle.status == :stopped
    assert Simulator.devices() == %{}
    assert :ok = Simulator.QemuTests.subscribe()
    assert :ok = Simulator.QemuTests.unsubscribe()
    refute firmware_started?()
    refute Process.whereis(NervesGate.Supervisor)
    refute Process.whereis(NervesGateWeb.Endpoint)

    :ok = stop_supervised(Dev.SessionServices)
    for {pid, ref} <- processes, do: assert_receive({:DOWN, ^ref, :process, ^pid, _})
    refute Process.whereis(NervesGate.PubSub)
    refute Process.whereis(Simulator.QemuTests)
    refute Process.whereis(DevWeb.Endpoint)
    assert Process.whereis(Simulator)
    assert Simulator.devices() == %{}
    refute firmware_started?()
  end

  defp firmware_started?,
    do: Enum.any?(Application.started_applications(), &(elem(&1, 0) == :nerves_gate))
end

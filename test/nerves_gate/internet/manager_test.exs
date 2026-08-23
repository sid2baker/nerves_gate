defmodule NervesGate.Internet.ManagerTest do
  use ExUnit.Case

  alias NervesGate.Internet.Config
  alias NervesGate.Internet.Manager
  alias NervesGate.Internet.Monitor
  alias NervesGate.TestInternetAdapter
  alias NervesGate.TestScenario

  setup do
    {:ok, _pid} = TestInternetAdapter.reset()
    :ok
  end

  test "Internet status preserves diagnostic causes behind one operational state" do
    checks = TestScenario.checks(%{physical_link: {:error, :no_carrier}})

    assert %{
             online: false,
             ready: false,
             reason: :no_carrier,
             checks: ^checks
           } = Monitor.summarize("eth0", checks)
  end

  test "configuration is applied only after verification" do
    manager = start_manager(fn _interface -> TestScenario.checks() end)
    config = TestScenario.dhcp()

    assert {:ok, checks} = Manager.configure(config, server: manager, timeout: 100)
    assert checks.internet_https == :ok
    assert %Config{method: :dhcp} = TestInternetAdapter.state().current
    assert Manager.status(manager).known_good.method == :dhcp
  end

  test "a failed candidate restores the previous runtime configuration" do
    mode = Agent.start_link(fn -> :ok end) |> elem(1)

    verifier = fn _interface ->
      case Agent.get(mode, & &1) do
        :ok -> TestScenario.checks()
        :fail -> TestScenario.checks(%{internet_https: {:error, :offline}})
      end
    end

    manager = start_manager(verifier)
    original = TestScenario.static()
    candidate = %{TestScenario.dhcp() | interface: "eth1"}

    assert {:ok, _checks} = Manager.configure(original, server: manager, timeout: 100)
    Agent.update(mode, fn _ -> :fail end)

    assert {:error, {:verification_failed, _checks}} =
             Manager.configure(candidate, server: manager, timeout: 20)

    assert TestInternetAdapter.state().current == original
    assert {:clear, "eth1"} in TestInternetAdapter.state().calls
    assert Manager.status(manager).known_good.method == :static
  end

  test "restore applies the active snapshot without creating persistence" do
    manager = start_manager(fn _interface -> TestScenario.checks() end)
    config = TestScenario.dhcp()

    assert :ok = Manager.restore(config, manager)
    assert TestInternetAdapter.state().current == config
    assert :ok = Manager.restore(nil, manager)
    assert TestInternetAdapter.state().current == nil
  end

  defp start_manager(verifier) do
    name = String.to_atom("network_manager_#{System.unique_integer([:positive])}")

    {:ok, manager} =
      Manager.start_link(name: name, adapter: TestInternetAdapter, verifier: verifier)

    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)
    manager
  end
end

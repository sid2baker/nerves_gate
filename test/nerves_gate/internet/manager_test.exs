defmodule NervesGate.Internet.ManagerTest do
  use ExUnit.Case

  alias NervesGate.Internet.Config
  alias NervesGate.Internet.Manager
  alias NervesGate.Internet.Monitor
  alias NervesGate.Store
  alias NervesGate.TestInternetAdapter
  alias NervesGate.TestScenario

  setup do
    {:ok, _pid} = TestInternetAdapter.reset()
    root = TestScenario.temporary_root(:network_manager)
    :ok = Store.initialize(root)

    on_exit(fn ->
      File.rm_rf!(root)
    end)

    %{root: root}
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

  test "DHCP success is verified before persistence", %{root: root} do
    pid = start_manager(root, fn _interface -> TestScenario.checks() end)
    config = TestScenario.dhcp()

    assert {:ok, checks} = Manager.apply_candidate(config, server: pid, timeout: 100)
    assert checks.internet_https == :ok
    assert {:ok, %Config{method: :dhcp}} = Store.read_network(root)
  end

  test "DHCP failure can be followed by known-good static configuration", %{root: root} do
    verifier = fn _interface ->
      case TestInternetAdapter.state().current do
        %Config{method: :dhcp} -> TestScenario.checks(%{ip_address: {:error, :dhcp_failed}})
        %Config{method: :static} -> TestScenario.checks()
      end
    end

    pid = start_manager(root, verifier)

    assert {:error, {:verification_failed, _checks}} =
             Manager.apply_candidate(TestScenario.dhcp(), server: pid, timeout: 20)

    assert {:ok, _checks} =
             Manager.apply_candidate(TestScenario.static(), server: pid, timeout: 100)

    assert {:ok, %Config{method: :static}} = Store.read_network(root)
  end

  test "wrong gateway or DNS rolls back without overwriting last-known-good", %{root: root} do
    known_good = TestScenario.dhcp()
    :ok = Store.write_network(known_good, root)

    verifier = fn _interface ->
      TestScenario.checks(%{
        default_route: {:error, :wrong_gateway},
        dns: {:error, :bad_dns},
        internet_https: {:error, :unreachable}
      })
    end

    pid = start_manager(root, verifier)
    candidate = TestScenario.static("eth0", "192.0.2.254")

    assert {:error, {:verification_failed, checks}} =
             Manager.apply_candidate(candidate, server: pid, timeout: 20)

    assert checks.dns == {:error, :bad_dns}
    assert {:ok, ^known_good} = Store.read_network(root)
    assert %Config{method: :dhcp} = TestInternetAdapter.state().current
  end

  test "loss and recovery of Internet preserves and re-verifies network state", %{root: root} do
    online? =
      Agent.get_and_update(TestInternetAdapter, fn state ->
        {true, Map.put(state, :online, false)}
      end)

    assert online?

    verifier = fn _interface ->
      if Agent.get(TestInternetAdapter, &Map.get(&1, :online, false)) do
        TestScenario.checks()
      else
        TestScenario.checks(%{internet_https: {:error, :offline}})
      end
    end

    pid = start_manager(root, verifier)
    config = TestScenario.dhcp()

    assert {:error, {:verification_failed, _checks}} =
             Manager.apply_candidate(config, server: pid, timeout: 20)

    Agent.update(TestInternetAdapter, &Map.put(&1, :online, true))
    assert {:ok, _checks} = Manager.apply_candidate(config, server: pid, timeout: 100)
    assert {:ok, ^config} = Store.read_network(root)
  end

  test "failed network change automatically restores the working candidate", %{root: root} do
    original = TestScenario.static()
    :ok = Store.write_network(original, root)

    pid =
      start_manager(root, fn _interface ->
        TestScenario.checks(%{internet_https: {:error, :timeout}})
      end)

    assert {:error, {:verification_failed, _checks}} =
             Manager.apply_candidate(TestScenario.dhcp(), server: pid, timeout: 20)

    assert TestInternetAdapter.state().current == original
  end

  defp start_manager(root, verifier) do
    name = String.to_atom("network_manager_#{System.unique_integer([:positive])}")

    {:ok, pid} =
      Manager.start_link(name: name, root: root, adapter: TestInternetAdapter, verifier: verifier)

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end
end

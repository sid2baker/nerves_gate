defmodule NervesGate.InternetTest do
  use ExUnit.Case

  alias NervesGate.Internet
  alias NervesGate.TestInternetAdapter
  alias NervesGate.TestScenario

  setup do
    {:ok, _pid} = TestInternetAdapter.reset()
    :ok
  end

  test "configuration traverses apply and verify before becoming online" do
    machine = start_machine(fn _interface -> TestScenario.checks() end)
    config = TestScenario.dhcp()

    assert {:ok, checks} = Internet.configure(config, server: machine, timeout: 100)
    assert checks.internet_https == :ok
    assert TestInternetAdapter.state().current == config
    assert Internet.status(machine).online
    assert Internet.configuration_status(machine).known_good.method == :dhcp

    events = Internet.diagnostics(machine).history |> Enum.map(& &1.event)
    assert :configure in events
    assert :configuration_completed in events
  end

  test "verification failure rolls back to the previous accepted runtime" do
    mode = Agent.start_link(fn -> :ok end) |> elem(1)

    verifier = fn _interface ->
      case Agent.get(mode, & &1) do
        :ok -> TestScenario.checks()
        :fail -> TestScenario.checks(%{internet_https: {:error, :offline}})
      end
    end

    machine = start_machine(verifier)
    original = TestScenario.static()
    candidate = %{TestScenario.dhcp() | interface: "eth1"}

    assert {:ok, _checks} = Internet.configure(original, server: machine, timeout: 100)
    Agent.update(mode, fn _ -> :fail end)

    assert {:error, {:verification_failed, _checks}} =
             Internet.configure(candidate, server: machine, timeout: 20)

    assert TestInternetAdapter.state().current == original
    assert {:clear, "eth1"} in TestInternetAdapter.state().calls
    assert Internet.configuration_status(machine).known_good.method == :static
  end

  test "connectivity observations change only the Internet contract" do
    checks = Agent.start_link(fn -> TestScenario.checks() end) |> elem(1)
    machine = start_machine(fn _ -> Agent.get(checks, & &1) end)
    assert {:ok, _} = Internet.configure(TestScenario.dhcp(), server: machine, timeout: 100)

    Agent.update(checks, fn _ -> TestScenario.checks(%{dns: {:error, :offline}}) end)
    assert :ok = Internet.poll_now(machine)
    assert %{online: false, reason: :dns_failure} = Internet.status(machine)

    Agent.update(checks, fn _ -> TestScenario.checks() end)
    assert :ok = Internet.poll_now(machine)
    assert Internet.status(machine).online
  end

  test "passive observations keep the last known public lifecycle" do
    owner = self()

    machine =
      start_machine(fn _ -> TestScenario.checks() end, fn status ->
        send(owner, {:published, status})
      end)

    assert {:ok, _checks} = Internet.configure(TestScenario.dhcp(), server: machine, timeout: 100)
    drain_published()

    assert :ok = Internet.poll_now(machine)
    statuses = drain_published()

    assert statuses != []
    assert Enum.all?(statuses, &(&1.state == :online))
    assert Internet.diagnostics(machine).state == :online
  end

  test "physical link healing observes without reapplying configuration" do
    checks = Agent.start_link(fn -> TestScenario.checks() end) |> elem(1)
    machine = start_machine(fn _ -> Agent.get(checks, & &1) end)
    assert {:ok, _} = Internet.configure(TestScenario.dhcp(), server: machine, timeout: 100)
    calls = length(TestInternetAdapter.state().calls)

    Agent.update(checks, fn _ -> TestScenario.checks(%{physical_link: {:error, :no_carrier}}) end)
    assert :ok = Internet.poll_now(machine)
    assert {:error, :physical_link_down} = Internet.heal(machine)
    assert length(TestInternetAdapter.state().calls) == calls
  end

  test "summarization retains normalized diagnostic causes" do
    checks = TestScenario.checks(%{physical_link: {:error, :no_carrier}})

    assert %{online: false, ready: false, reason: :no_carrier, checks: ^checks} =
             Internet.summarize("eth0", checks)
  end

  defp start_machine(verifier, publisher \\ fn _status -> :ok end) do
    name = String.to_atom("internet_machine_#{System.unique_integer([:positive])}")

    payload =
      Internet.new(
        adapter: TestInternetAdapter,
        verifier: verifier,
        publisher: publisher,
        configuration_publisher: fn _ -> :ok end,
        alarm_reporter: fn _current, _previous -> :ok end
      )

    {:ok, machine} = Internet.start_link(payload: payload, name: name)
    machine
  end

  defp drain_published(statuses \\ []) do
    receive do
      {:published, status} -> drain_published([status | statuses])
    after
      0 -> Enum.reverse(statuses)
    end
  end
end

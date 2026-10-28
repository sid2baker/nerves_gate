defmodule Workbench.OperationsCommandsTest do
  use ExUnit.Case, async: false

  test "commands require explicit selections before touching a session" do
    assert_raise Mix.Error, ~r/--device/, fn -> Workbench.CLI.Scenario.run(["sdk"]) end
    assert_raise Mix.Error, ~r/--device/, fn -> Workbench.CLI.Scenario.ci(["sdk"]) end

    assert_raise Mix.Error, ~r/--device/, fn ->
      Workbench.CLI.Plugin.run(:install, ["plugins/modbus"])
    end

    assert_raise Mix.Error, ~r/Usage/, fn -> Workbench.CLI.Scenario.run([]) end

    assert_raise OptionParser.ParseError, fn ->
      Workbench.CLI.Scenario.run(["sdk", "--lifecycle", "reset"])
    end

    assert_raise OptionParser.ParseError, fn -> Workbench.Launcher.dev(["--ci"]) end
    refute File.exists?(Path.join(Workbench.root(), "lib/mix/tasks/test.qemu.ex"))
  end

  test "prerequisite and network diagnostics only observe" do
    journal = Path.join(Workbench.root(), "_build/workbench/network.term")
    before = File.read(journal)
    status = Simulator.Prerequisites.status()
    assert is_boolean(status.supported_host)
    assert Enum.all?(status.tools, fn {_, present} -> is_boolean(present) end)
    refute Map.has_key?(status.tools, "socat")
    assert %{status: state} = Workbench.ManagementNetwork.status()
    assert state in [:not_prepared, :ready, :unavailable, :unreadable]
    assert File.read(journal) == before
  end

  test "directory resolution rejects ambiguity, missing and implicit targets" do
    a = %{node: :"nerves_gate@10.0.0.1", address: "10.0.0.1", sim_id: :a, connected: true}
    b = %{a | node: :"nerves_gate@10.0.0.2", address: "10.0.0.2"}
    assert {:ok, ^a} = Workbench.Gateways.resolve([a], "a")
    assert {:ok, ^a} = Workbench.Gateways.resolve([a], a.address)
    assert {:error, :ambiguous_target} = Workbench.Gateways.resolve([a, b], "a")
    assert {:error, :not_connected} = Workbench.Gateways.resolve([%{a | connected: false}], "a")
    assert {:error, _} = Workbench.Gateways.resolve([a], nil)
  end

  test "build exclusion is cross-process, reentrant, and releases on normal completion" do
    parent = self()

    pid =
      spawn(fn ->
        Workbench.BuildLock.run!(fn ->
          assert Workbench.BuildLock.run!(fn -> :nested end) == :nested
          send(parent, :locked)

          receive do
            :release -> :ok
          end
        end)

        send(parent, :released)
      end)

    assert_receive :locked

    assert_raise RuntimeError, ~r/Another build/, fn ->
      Workbench.BuildLock.run!(fn -> flunk("must not run") end)
    end

    send(pid, :release)
    assert_receive :released
    # Port close releases the OS helper asynchronously; wait for its exit without replaying work.
    Process.sleep(50)
    assert Workbench.BuildLock.run!(fn -> :available end) == :available
  end
end

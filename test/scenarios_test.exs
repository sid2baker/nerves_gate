defmodule Dev.ScenariosTest do
  use ExUnit.Case, async: true
  alias Dev.{Scenarios, TestDevice}

  # These exercise execution/requirement policy, not simulated hardware or an SDK
  # backend. They never make RPC calls or control a device.
  defmodule Passing do
    def spec, do: %{name: "Execution order", requires: %{device: [], fixture: []}}
    def run(_), do: send(self(), :body)
  end

  defmodule Unsupported do
    def spec do
      %{
        name: "Needs an owned power control",
        requires: %{device: [:ethernet], fixture: [:power_cycle]},
        fresh_disk: true
      }
    end

    def run(_), do: raise("Unsupported scenario must not execute")
  end

  defmodule Failing do
    def spec, do: %{name: "Broken assertion", requires: %{device: [], fixture: []}}
    def run(_), do: raise(ExUnit.AssertionError, message: "contract violation")
  end

  defmodule Uncertain do
    def spec, do: %{name: "Uncertain control", requires: %{device: [], fixture: []}}
    def run(_), do: exit(:control_outcome_unknown)
  end

  test "requirements distinguish device resources from fixture controls" do
    required = %{device: [:ethernet, :rs485], fixture: [:ethernet_link]}

    assert {:skip, "Missing requirements: device:rs485, fixture:ethernet_link"} =
             Scenarios.requirements(required, %{device: [:ethernet], fixture: []})

    assert :ok =
             Scenarios.requirements(required, %{
               device: [:ethernet, :rs485],
               fixture: [:ethernet_link]
             })
  end

  test "missing controls skip before RPC, disk preparation or the scenario body" do
    context = %{device: %{}}

    assert %{status: :skipped, detail: "Missing requirements: fixture:power_cycle"} =
             Scenarios.run(Unsupported, context, fn -> send(self(), :prepared) end)

    refute_received :prepared
  end

  test "a scenario runs only after successful preparation" do
    assert %{status: :passed} =
             Scenarios.run(Passing, %{device: %{}}, fn ->
               send(self(), :prepared)
               :ok
             end)

    assert_received :prepared
    assert_received :body
  end

  test "assertions and preparation failures are failures, never skips" do
    assert %{status: :failed, detail: detail} = Scenarios.run(Failing, %{device: %{}})
    assert detail =~ "contract violation"

    assert %{status: :failed} =
             Scenarios.run(Passing, %{device: %{}}, fn -> raise "preparation failed" end)

    refute_received :body
  end

  test "unknown control exits propagate to the reservation owner without retries" do
    assert catch_exit(Scenarios.run(Uncertain, %{device: %{}})) == :control_outcome_unknown
  end

  test "skips do not turn an empty, failed or interrupted run green" do
    assert Scenarios.result([]) == :skipped
    assert Scenarios.result([%{status: :skipped}]) == :skipped
    assert Scenarios.result([%{status: :passed}, %{status: :skipped}]) == :passed
    assert Scenarios.result([%{status: :passed}, %{status: :failed}]) == :failed
    assert Scenarios.result([%{status: :passed}, %{status: :running}]) == :failed
    assert Scenarios.result([%{status: :waiting}]) == :failed
  end

  test "fixture controls are never inferred from a node or board" do
    assert TestDevice.fixture_capabilities(%{node: :qemu, target: :x86_64}) == []
    assert TestDevice.control(%{}, :power_cycle) == {:error, :unsupported_fixture_control}

    target = %{fixture: {Simulator.TestQemu, %{}}}
    assert TestDevice.control(target, :format_disk) == {:error, :unsupported_fixture_control}

    for name <- ["usb0", "eth2", "lo", "../eth0"] do
      assert TestDevice.control(target, :ethernet_link, [name, false]) ==
               {:error, :unsupported_fixture_control}
    end
  end

  test "declared resources stay supported when disconnected or disabled" do
    status = hardware_status()
    assert TestDevice.resources(status) == [:ethernet, :cellular, :can, :rs485]
    assert :ok = TestDevice.assert_present(status, [:ethernet, :cellular, :can, :rs485])
  end

  test "unsupported hardware skips rather than failing a presence check" do
    status = %{
      hardware_status()
      | cellular: %{supported: false, present: nil},
        buses: %{available: false, ports: []}
    }

    assert TestDevice.resources(status) == [:ethernet]

    assert {:skip, "Missing requirements: device:can, device:rs485, device:cellular"} =
             Scenarios.requirements(
               %{device: [:can, :rs485, :cellular]},
               %{device: TestDevice.resources(status)}
             )
  end

  test "missing or unobserved declared buses fail instead of becoming unsupported" do
    for present <- [false, nil] do
      status = hardware_status()
      ports = Enum.map(status.buses.ports, &Map.put(&1, :present, present))
      status = put_in(status.buses.ports, ports)

      assert TestDevice.resources(status) == [:ethernet, :cellular, :can, :rs485]

      assert :ok =
               Scenarios.requirements(%{device: [:can, :rs485]}, %{
                 device: TestDevice.resources(status)
               })

      assert_raise ExUnit.AssertionError, ~r/Expected hardware missing or unobserved: can0/, fn ->
        TestDevice.assert_present(status, [:can])
      end

      assert_raise ExUnit.AssertionError,
                   ~r/Expected hardware missing or unobserved: ttyS3/,
                   fn ->
                     TestDevice.assert_present(status, [:rs485])
                   end

      # Broken hardware unrelated to this scenario must not prevent its execution.
      assert :ok = TestDevice.assert_present(status, [:ethernet])
    end
  end

  test "declared Ethernet and modem hardware must also be present when required" do
    for present <- [false, nil] do
      status = put_in(hardware_status(), [:connections, :ports, Access.at(0), :present], present)

      assert_raise ExUnit.AssertionError,
                   ~r/Expected hardware missing or unobserved: enp1s0/,
                   fn ->
                     TestDevice.assert_present(status, [:ethernet])
                   end

      status = put_in(hardware_status(), [:cellular, :present], present)
      assert :cellular in TestDevice.resources(status)

      assert_raise ExUnit.AssertionError,
                   ~r/Expected hardware missing or unobserved: cellular modem/,
                   fn ->
                     TestDevice.assert_present(status, [:cellular])
                   end
    end
  end

  test "portable and QEMU scenarios share one catalogue with unique IDs" do
    scenarios = Simulator.QemuTests.scenarios()
    ids = Enum.map(scenarios, & &1.id)
    assert ids == Enum.sort(ids)
    assert ids == Enum.uniq(ids)

    for scenario <- Scenarios.all() do
      assert scenario in scenarios
      assert :qemu not in Map.get(scenario.requires, :fixture, [])
    end

    assert [%{module: Dev.Scenarios.PublicStatus}] =
             Simulator.QemuTests.scenarios("public_status")

    assert [%{module: Dev.Scenarios.Sdk}] = Simulator.QemuTests.scenarios("sdk")
    assert [%{requires: %{fixture: [:qemu]}}] = Simulator.QemuTests.scenarios("power_trial")
    assert [%{module: Simulator.Scenarios.QemuSdk}] = Simulator.QemuTests.scenarios("qemu_sdk")
  end

  defp hardware_status do
    %{
      connections: %{
        ports: [%{name: "enp1s0", present: true, link: false, addresses: []}]
      },
      cellular: %{supported: true, present: true, enabled: false},
      buses: %{
        available: true,
        ports: [
          %{name: "can0", transport: "can", present: true, up: false},
          %{name: "ttyS3", transport: "rs485", present: true, enabled: false}
        ]
      }
    }
  end
end

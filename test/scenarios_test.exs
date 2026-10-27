defmodule Workbench.ScenariosTest do
  use ExUnit.Case, async: true
  alias Scenarios
  alias Scenarios.Device, as: Device

  # These exercise requirements and bounded transport failures, not simulated
  # hardware or an SDK backend. They never control a device.
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
    assert Device.fixture_capabilities(%{node: :qemu, target: :x86_64}) == []
    assert Device.control(%{}, :power_cycle) == {:error, :unsupported_fixture_control}

    assert Device.fixture_capabilities(%{fixture: {Scenarios.Qemu, %{owner: self()}}}) == []

    target = %{fixture: {:qemu, %{owner: self()}}}
    assert :ethernet_link in Device.fixture_capabilities(target)
    assert Device.control(target, :format_disk) == {:error, :unsupported_fixture_control}

    for name <- ["usb0", "eth2", "lo", "../eth0"] do
      assert Device.control(target, :ethernet_link, [name, false]) ==
               {:error, :unsupported_fixture_control}
    end
  end

  test "declared resources stay supported when disconnected or disabled" do
    status = hardware_status()
    assert Device.resources(status) == [:ethernet, :cellular, :can, :rs485]
    assert :ok = Device.assert_present(status, [:ethernet, :cellular, :can, :rs485])
  end

  test "unsupported hardware skips rather than failing a presence check" do
    status = %{
      hardware_status()
      | cellular: %{supported: false, present: nil},
        buses: %{available: false, ports: []}
    }

    assert Device.resources(status) == [:ethernet]

    assert {:skip, "Missing requirements: device:can, device:rs485, device:cellular"} =
             Scenarios.requirements(
               %{device: [:can, :rs485, :cellular]},
               %{device: Device.resources(status)}
             )
  end

  test "missing or unobserved declared buses fail instead of becoming unsupported" do
    for present <- [false, nil] do
      status = hardware_status()
      ports = Enum.map(status.buses.ports, &Map.put(&1, :present, present))
      status = put_in(status.buses.ports, ports)

      assert Device.resources(status) == [:ethernet, :cellular, :can, :rs485]

      assert :ok =
               Scenarios.requirements(%{device: [:can, :rs485]}, %{
                 device: Device.resources(status)
               })

      assert_raise ExUnit.AssertionError, ~r/Expected hardware missing or unobserved: can0/, fn ->
        Device.assert_present(status, [:can])
      end

      assert_raise ExUnit.AssertionError,
                   ~r/Expected hardware missing or unobserved: ttyS3/,
                   fn ->
                     Device.assert_present(status, [:rs485])
                   end

      # Broken hardware unrelated to this scenario must not prevent its execution.
      assert :ok = Device.assert_present(status, [:ethernet])
    end
  end

  test "declared Ethernet and modem hardware must also be present when required" do
    for present <- [false, nil] do
      status = put_in(hardware_status(), [:connections, :ports, Access.at(0), :present], present)

      assert_raise ExUnit.AssertionError,
                   ~r/Expected hardware missing or unobserved: enp1s0/,
                   fn ->
                     Device.assert_present(status, [:ethernet])
                   end

      status = put_in(hardware_status(), [:cellular, :present], present)
      assert :cellular in Device.resources(status)

      assert_raise ExUnit.AssertionError,
                   ~r/Expected hardware missing or unobserved: cellular modem/,
                   fn ->
                     Device.assert_present(status, [:cellular])
                   end
    end
  end

  test "portable and QEMU scenarios share one catalogue with unique IDs" do
    scenarios = Scenarios.all()
    ids = Enum.map(scenarios, & &1.id)
    assert ids == Enum.sort(ids)
    assert ids == Enum.uniq(ids)

    portable = ~w(cable_loss invalid_configuration invalid_trial_ids public_status sdk)
    assert length(scenarios) == 46

    for scenario <- scenarios do
      assert Enum.sort(Map.keys(scenario.requires)) == [:device, :fixture]
      assert is_boolean(scenario.fresh_disk)
      assert is_boolean(scenario.all)
      assert is_boolean(scenario.opt_in)

      assert :qemu in scenario.requires.fixture ==
               scenario.id not in ["hardware_readiness", "hardware_backup" | portable]

      assert :usb_management in scenario.requires.fixture == (scenario.id == "hardware_backup")
      assert :ssh_management in scenario.requires.fixture == (scenario.id == "hardware_readiness")
    end

    assert [%{module: Scenarios.Cases.PublicStatus}] =
             Scenarios.select("public_status")

    assert [%{module: Scenarios.Cases.Sdk}] = Scenarios.select("sdk")
    assert [%{requires: %{fixture: [:qemu]}}] = Scenarios.select("power_trial")
    assert [%{module: Scenarios.Cases.QemuSdk}] = Scenarios.select("qemu_sdk")

    assert [%{module: Scenarios.Cases.AppUI, fresh_disk: true, requires: %{fixture: [:qemu]}}] =
             Scenarios.select("app_ui")
  end

  test "an uncertain RPC stops the worker before further commands or cleanup" do
    device = %{node: :cutover_unreachable@localhost}

    assert catch_exit(Device.rpc(device, NervesGate.Network, :confirm, ["not-sent"])) ==
             :simulator_control_failed

    assert Process.get(:simulator_control_failed)
    assert catch_exit(Device.rpc(%{node: node()}, Kernel, :self)) == :simulator_control_failed
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

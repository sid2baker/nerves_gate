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

  defmodule KnownFailure do
    def spec, do: %{name: "Stopped before submission", requires: %{device: [], fixture: []}}
    def run(_), do: {:error, :known, "No SMS submitted"}
  end

  defmodule Uncertain do
    def spec, do: %{name: "Uncertain control", requires: %{device: [], fixture: []}}
    def run(_), do: exit(:control_outcome_unknown)
  end

  test "physical remote access is explicit and skips before access on nonphysical fixtures" do
    scenario = Scenarios.describe(Scenarios.Cases.PhysicalRemoteAccess)
    assert scenario in Scenarios.physical()
    assert scenario.opt_in
    refute scenario.fresh_disk
    refute scenario.all
    assert scenario.requires == %{device: [], fixture: [:physical]}
    refute scenario in Scenarios.all()

    assert %{status: :skipped, detail: "Missing requirements: fixture:physical"} =
             Scenarios.run(scenario, %{device: %{}}, fn -> send(self(), :prepared) end)

    refute_received :prepared
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

  test "explicit known failures and missing prerequisites retain their certainty" do
    assert %{status: :failed, certainty: :known, detail: "No SMS submitted"} =
             Scenarios.run(KnownFailure, %{device: %{}})

    assert %{status: :skipped, certainty: :known} = Scenarios.run(Unsupported, %{device: %{}})
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
        hardware: %{available: false, ports: []}
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
      ports = Enum.map(status.hardware.ports, &Map.put(&1, :present, present))
      status = put_in(status.hardware.ports, ports)

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

    portable = ~w(invalid_configuration invalid_trial_ids public_status sdk)
    assert length(scenarios) == 44

    for scenario <- scenarios do
      assert Enum.sort(Map.keys(scenario.requires)) == [:device, :fixture]
      assert is_boolean(scenario.fresh_disk)
      assert is_boolean(scenario.all)
      assert is_boolean(scenario.opt_in)

      assert :qemu in scenario.requires.fixture == scenario.id not in portable
    end

    # Physical checks are separate: only physical gateways run them, one at a time.
    assert Enum.map(Scenarios.physical(), & &1.id) ==
             ~w(hardware_readiness physical_remote_access cellular_modem_support cellular_sms_submit hardware_backup button_reboot)

    for check <- Scenarios.physical(),
        do: assert(check.requires.fixture == [:physical] and check.opt_in)

    assert [%{module: Scenarios.Cases.PublicStatus}] =
             Scenarios.select("public_status")

    assert [%{module: Scenarios.Cases.Sdk}] = Scenarios.select("sdk")
    assert [%{requires: %{fixture: [:qemu]}}] = Scenarios.select("power_trial")
    assert [%{module: Scenarios.Cases.QemuSdk}] = Scenarios.select("qemu_sdk")

    assert [%{module: Scenarios.Cases.Plugins, fresh_disk: true, requires: %{fixture: [:qemu]}}] =
             Scenarios.select("plugins")
  end

  test "modem qualification is opt-in, physical-only and requires cellular hardware" do
    check = Enum.find(Scenarios.physical(), &(&1.id == "cellular_modem_support"))
    assert check.requires == %{device: [:cellular], fixture: [:physical]}
    assert check.opt_in
    assert Scenarios.select("cellular_modem_support") == []
    refute check.fresh_disk
  end

  test "USSD capability classification requires an explicit supported request mode" do
    alias Scenarios.Cases.CellularModemSupport, as: Probe

    for modes <- ["0-2", "0,1,2", "0, 1, 2", "0-1", "1", "1-2"] do
      assert Probe.classify({:ok, ["+CUSD: (#{modes})"]}) == :supported
    end

    for lines <- [
          [],
          ["OK"],
          ["+CUSD: (0)"],
          ["+CUSD: (2)"],
          ["+CUSD: (1,3)"],
          ["+CUSD: (2-1)"],
          ["+CUSD: (0-2)", "+CUSD: (0)"],
          ["+CUSD: 0,\"Guthaben 12,34 EUR\",15"],
          ["+CUSD: (1) private trailing data"],
          [String.duplicate("x", 256)],
          ["+CUSD: (1)" <> <<255>>],
          [nil, :unknown]
        ] do
      assert Probe.classify({:ok, lines}) == :inconclusive
    end

    assert Probe.classify({:error, :error}) == :rejected
    assert Probe.classify({:error, {:cme, "operation not supported"}}) == :rejected
    assert Probe.classify({:error, :timeout}) == :timeout
    assert Probe.classify({:error, :not_running}) == :inconclusive
    assert Probe.classify(nil) == :inconclusive
  end

  test "USSD diagnostics expose only known error causes and safe mode fields" do
    alias Scenarios.Cases.CellularModemSupport, as: Probe

    assert Probe.describe("AT", {:ok, ["private unsolicited message"]}) == "OK"

    for {mode, description} <- [
          {0, "extended errors disabled"},
          {1, "numeric extended errors"},
          {2, "verbose extended errors"}
        ] do
      assert Probe.describe("AT+CMEE?", {:ok, ["+CMEE: #{mode}"]}) ==
               "CMEE=#{mode} (#{description})"

      assert Probe.describe("AT+CUSD?", {:ok, ["+CUSD: #{mode}"]}) == "CUSD=#{mode}"
    end

    assert Probe.describe("AT+CUSD=?", {:ok, ["+CUSD: (0-2)"]}) ==
             "OK; request mode 1 advertised"

    assert Probe.describe("AT+CUSD=?", {:ok, []}) ==
             "OK; no recognized request-mode advertisement"

    assert Probe.describe("AT+CUSD?", {:error, :error}) ==
             "ERROR (no extended cause supplied)"

    for detail <- ["4", "operation not supported", " Operation Not Supported "] do
      assert Probe.describe("AT+CUSD=?", {:error, {:cme, detail}}) ==
               "CME: operation not supported"
    end

    assert Probe.describe("AT+CUSD=?", {:error, {:cme, "3"}}) ==
             "CME: operation not allowed"

    assert Probe.describe("AT+CUSD=?", {:error, {:cme, "30"}}) == "CME: no network service"
    assert Probe.describe("AT+CUSD=?", {:error, {:cme, "515"}}) == "CME code 515"
    assert Probe.describe("AT+CUSD=?", {:error, :timeout}) == "timeout"

    assert Probe.describe("AT", {:error, :not_running}) ==
             "controller unavailable or call outcome unknown"

    for detail <- ["private subscriber data", "1234", <<255>>, nil, String.duplicate("x", 65)] do
      assert Probe.describe("AT+CUSD=?", {:error, {:cme, detail}}) ==
               "CME error (unrecognized detail withheld)"
    end

    for lines <- [
          ["+CUSD: 0,\"private payload\",15"],
          ["+CUSD: 1", "+CUSD: 0"],
          ["+CUSD: 9"],
          ["+CUSD: " <> <<255>>],
          [nil],
          :unexpected
        ] do
      assert Probe.describe("AT+CUSD?", {:ok, lines}) == "OK; USSD mode not recognized"
    end

    assert Probe.describe("AT+CMEE?", {:ok, ["+CMEE: 2 private data"]}) ==
             "OK; error mode not recognized"

    assert Probe.describe("AT", {:error, {:unexpected, "private data"}}) ==
             "inconclusive (details withheld)"
  end

  test "SMS qualification requires PDU format and every command test, independently of USSD" do
    alias Scenarios.Cases.CellularModemSupport, as: Probe

    tests = ~w(AT+CMGS=? AT+CMGR=? AT+CMGL=? AT+CMGD=? AT+CPMS=?)
    responses = Map.new(tests, &{&1, {:ok, []}})
    responses = Map.put(responses, "AT+CMGF=?", {:ok, ["+CMGF: (0,1)"]})
    assert Probe.sms_supported?(responses)
    assert Probe.sms_supported?(Map.put(responses, "AT+CUSD=?", {:error, :error}))

    for command <- tests do
      refute Probe.sms_supported?(Map.delete(responses, command))
      refute Probe.sms_supported?(Map.put(responses, command, {:error, :error}))
      refute Probe.sms_supported?(Map.put(responses, command, {:error, :timeout}))
      refute Probe.sms_supported?(Map.put(responses, command, {:ok, :malformed}))
    end

    for lines <- [["+CMGF: (1)"], [], ["+CMGF: (0)", "+CMGF: (1)"], ["+CMGF: private"]] do
      refute Probe.sms_supported?(Map.put(responses, "AT+CMGF=?", {:ok, lines}))
    end

    assert Probe.sms_supported?(Map.put(responses, "AT+CMGF=?", {:ok, ["+CMGF: (0-1)"]}))
    refute Probe.sms_supported?(nil)
  end

  test "SMS qualification reports only recognized model, revision, format and storage metadata" do
    alias Scenarios.Cases.CellularModemSupport, as: Probe

    assert Probe.describe("AT+CGMM", {:ok, ["EG800AK", "private unsolicited data"]}) == "EG800AK"
    assert Probe.describe("AT+CGMR", {:ok, ["EG800AKGLR01A01M01"]}) == "EG800AKGLR01A01M01"

    assert Probe.describe("AT+CGMM", {:ok, ["private subscriber data"]}) ==
             "OK; model/revision not recognized (details withheld)"

    assert Probe.describe("AT+CGMR", {:ok, ["EG800AK", "EG800AK"]}) ==
             "OK; model/revision not recognized (details withheld)"

    assert Probe.describe("AT+CMGF=?", {:ok, ["+CMGF: (0-1)"]}) == "OK; PDU format advertised"
    assert Probe.describe("AT+CMGF=?", {:ok, ["+CMGF: (1)"]}) == "OK; PDU format not established"
    assert Probe.describe("AT+CMGF?", {:ok, ["+CMGF: 0"]}) == "PDU format selected"
    assert Probe.describe("AT+CMGF?", {:ok, ["+CMGF: 1"]}) == "text format selected"
    assert Probe.describe("AT+CMGF?", {:ok, ["+CMGF: 2"]}) == "OK; SMS format not recognized"
    assert Probe.describe("AT+CMGS=?", {:ok, []}) == "OK; command test accepted"

    assert Probe.describe("AT+CMGR=?", {:error, {:cms, "private data"}}) ==
             "CMS error (details withheld)"

    assert Probe.describe("AT+CPMS?", {:ok, [~s(+CPMS: "SM",2,20,"ME",0,100,"ME",0,100)]}) ==
             "read=SM:2/20, write=ME:0/100, receive=ME:0/100"

    for lines <- [
          [~s(+CPMS: "SM",21,20,"ME",0,100,"ME",0,100)],
          [~s(+CPMS: "private",2,20,"ME",0,100,"ME",0,100)],
          ["+CPMS: private data"],
          ["+CPMS: " <> <<255>>],
          [],
          :malformed
        ] do
      assert Probe.describe("AT+CPMS?", {:ok, lines}) == "OK; storage counts not recognized"
    end
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
      hardware: %{
        available: true,
        ports: [
          %{id: "can0", kind: :can, present: true, up: false},
          %{id: "ttyS3", kind: :rs485, present: true, enabled: false}
        ]
      }
    }
  end
end

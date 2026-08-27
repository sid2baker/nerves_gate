defmodule NervesGate.FirmwareTest.Platform do
  @behaviour NervesGate.Firmware.Platform

  def status(options), do: {:ok, Agent.get(options[:platform_agent], & &1.report)}

  def install_verified(path, release, options) do
    send(options[:test_owner], {:install, path, release.id})

    case Agent.get(options[:platform_agent], &Map.get(&1, :install_result, :ok)) do
      :block ->
        send(options[:test_owner], :installation_blocked)
        Process.sleep(:infinity)

      result ->
        result
    end
  end

  def validate(options) do
    send(options[:test_owner], :validate)

    Agent.update(options[:platform_agent], fn state ->
      put_in(state.report.validation, :validated)
    end)
  end

  def synchronize(options) do
    send(options[:test_owner], :synchronize)

    Agent.update(options[:platform_agent], fn state ->
      report = %{state.report | next_slot: state.report.active_slot}
      %{state | report: report}
    end)
  end

  def revert(options) do
    send(options[:test_owner], :revert)

    Agent.get_and_update(options[:platform_agent], fn state ->
      result = Map.get(state, :revert_result, :ok)
      report = %{state.report | next_slot: opposite(state.report.active_slot)}
      {result, %{state | report: report}}
    end)
  end

  def reboot(options) do
    send(options[:test_owner], :reboot)
    Process.sleep(:infinity)
  end

  defp opposite("a"), do: "b"
  defp opposite("b"), do: "a"
end

defmodule NervesGate.FirmwareTest.Source do
  @behaviour NervesGate.Firmware.ReleaseSource

  def latest(_current, options) do
    case options[:test_release] do
      {:block, owner, release} ->
        send(owner, {:discovery_blocked, self()})

        receive do
          :continue_discovery -> {:ok, release}
        end

      release ->
        {:ok, release}
    end
  end
end

defmodule NervesGate.FirmwareTest.Artifact do
  alias NervesGate.Firmware.{Artifact, Release}

  def download(%Release{} = release, root, progress, _options) do
    path = Artifact.verified_path(root, release)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy(<<0>>, release.size))
    progress.(release.size)
    {:ok, path}
  end

  def verify(_path, release, _current, _options), do: {:ok, %{"uuid" => release.uuid}}
  def remove(release, root), do: Artifact.remove(release, root)
end

defmodule NervesGate.FirmwareTest do
  use ExUnit.Case, async: false

  alias NervesGate.Firmware
  alias NervesGate.Firmware.{Persistence, Release}
  alias NervesGate.FSM.Diagnostics
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:firmware)
    owner = self()

    {:ok, platform_agent} =
      Agent.start_link(fn -> %{report: report("1.0.0", "old", :validated, "a", "a")} end)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, owner: owner, platform_agent: platform_agent}
  end

  test "a check requested during discovery is coalesced into one fresh discovery", context do
    machine =
      start_machine(context,
        release_options: [test_release: {:block, context.owner, release()}]
      )

    assert_receive {:discovery_blocked, discovery}, 2_000
    assert :ok = Firmware.check(machine)
    await_state(machine, :checking)

    send(discovery, :continue_discovery)
    assert_receive {:discovery_blocked, fresh_discovery}, 2_000
    send(fresh_discovery, :continue_discovery)
    await_state(machine, :idle)
  end

  test "downloads and verifies before the platform can install", context do
    machine = start_machine(context)
    await_state(machine, :idle)

    assert :ok = Firmware.prepare(release().id, "connection-old", machine)
    await_state(machine, :ready)

    status = Firmware.status(machine)
    assert NervesGate.DeviceState.public?(status)
    assert is_binary(status.last_checked_at)
    assert status.artifact.verified
    assert status.progress == 100
    assert File.regular?(NervesGate.Firmware.Artifact.verified_path(context.root, release()))
    assert {:ok, %{phase: :ready}} = Persistence.load(context.root)

    assert :ok = Firmware.install(release().id, "connection-old", machine)
    assert_receive {:install, path, "new"}, 2_000
    assert File.regular?(path)
    assert_receive :reboot, 2_000
    await_state(machine, :rebooting)
  end

  test "preflight synchronizes platform boot authorities before installation", context do
    machine = start_machine(context)
    await_state(machine, :idle)
    :ok = Firmware.prepare(release().id, "connection-old", machine)
    await_state(machine, :ready)

    Agent.update(context.platform_agent, fn state ->
      %{state | report: %{state.report | active_slot: "a", next_slot: "b"}}
    end)

    assert :ok = Firmware.install(release().id, "connection-old", machine)
    assert_receive :synchronize, 2_000
    assert_receive {:install, _path, "new"}, 2_000
  end

  test "a new boot exposes an unvalidated trial and requires healthy fresh Tailnet acceptance",
       context do
    first = start_machine(context)
    await_state(first, :idle)
    :ok = Firmware.prepare(release().id, "connection-old", first)
    await_state(first, :ready)
    :ok = Firmware.install(release().id, "connection-old", first)
    assert_receive :reboot, 2_000
    GenServer.stop(first, :normal)

    candidate_boot(context.platform_agent)
    trial = start_machine(context, system_boot_id: "boot-new", device_boot_id: "device-new")
    await_state(trial, :trial)
    await_confirmable(trial)

    assert {:error, :tailnet_connection_required} =
             Firmware.accept("new", %{id: "fresh", tailnet?: false, boot_id: "device-new"}, trial)

    assert {:error, :fresh_connection_required} =
             Firmware.accept("new", %{id: "fresh", tailnet?: true, boot_id: "old-boot"}, trial)

    assert :ok =
             Firmware.accept(
               "new",
               %{id: "fresh", tailnet?: true, boot_id: "device-new"},
               trial
             )

    assert_receive :validate, 2_000
    await_state(trial, :idle)
    assert Firmware.status(trial).validation == :validated
    refute File.exists?(Persistence.path(context.root))
  end

  test "an unconfirmed trial schedules rollback and retains its journal until the old firmware boots",
       context do
    write_trial(context)
    candidate_boot(context.platform_agent)

    trial =
      start_machine(context,
        system_boot_id: "boot-new",
        device_boot_id: "device-new",
        trial_timeout: 10
      )

    await_state(trial, :trial)
    assert_receive :revert, 2_500
    assert_receive :reboot, 2_000
    assert {:ok, %{phase: :rolling_back}} = Persistence.load(context.root)
    GenServer.stop(trial, :normal)

    previous_boot(context.platform_agent)

    recovered =
      start_machine(context,
        system_boot_id: "boot-restored",
        device_boot_id: "device-restored"
      )

    await_state(recovered, :idle)
    assert Firmware.status(recovered).current.uuid == "old"
    refute File.exists?(Persistence.path(context.root))
  end

  test "a contained installer failure keeps the verified artifact retryable", context do
    machine = start_machine(context)
    await_state(machine, :idle)
    :ok = Firmware.prepare(release().id, "connection-old", machine)
    await_state(machine, :ready)

    Agent.update(context.platform_agent, &Map.put(&1, :install_result, {:error, :unavailable}))
    :ok = Firmware.install(release().id, "connection-old", machine)
    await_state(machine, :ready)

    assert Firmware.status(machine).artifact.verified
    assert Firmware.status(machine).last_error == :unavailable
  end

  test "power loss during installation leaves the old firmware active and the verified artifact retryable",
       context do
    machine = start_machine(context)
    await_state(machine, :idle)
    :ok = Firmware.prepare(release().id, "connection-old", machine)
    await_state(machine, :ready)

    Agent.update(context.platform_agent, &Map.put(&1, :install_result, :block))
    :ok = Firmware.install(release().id, "connection-old", machine)
    assert_receive :installation_blocked, 2_000
    assert {:ok, %{phase: :installing}} = await_journal(context.root, :installing)
    GenServer.stop(machine, :normal)

    Agent.update(context.platform_agent, &Map.put(&1, :install_result, :ok))
    recovered = start_machine(context)
    await_state(recovered, :ready)
    assert Firmware.status(recovered).current.uuid == "old"
    assert Firmware.status(recovered).artifact.verified
  end

  test "configuration-changing operations report firmware as busy throughout trial", context do
    write_trial(context)
    candidate_boot(context.platform_agent)
    machine = start_machine(context, system_boot_id: "boot-new", device_boot_id: "device-new")
    await_state(machine, :trial)
    assert Firmware.busy?(machine)
  end

  defp start_machine(context, options \\ []) do
    name = String.to_atom("firmware_machine_#{System.unique_integer([:positive])}")

    platform_options = [platform_agent: context.platform_agent, test_owner: context.owner]

    defaults = [
      root: context.root,
      platform: NervesGate.FirmwareTest.Platform,
      platform_options: platform_options,
      release_source: NervesGate.FirmwareTest.Source,
      release_options: [test_release: release()],
      artifact: NervesGate.FirmwareTest.Artifact,
      artifact_options: [],
      publisher: fn status -> send(context.owner, {:published, status}) end,
      health_provider: fn -> healthy() end,
      preflight_provider: fn _release, _report -> {:ok, healthy()} end,
      stable_window: 0,
      check_interval: :timer.hours(1),
      effect_timeout: 5_000,
      uptime: fn -> 0 end,
      system_boot_id: "boot-old",
      device_boot_id: "device-old"
    ]

    payload = Firmware.new(Keyword.merge(defaults, options))

    {:ok, machine} = Firmware.start_link(payload: payload, name: name)
    assert {:ok, _state} = Diagnostics.transition(machine, :activate)
    machine
  end

  defp write_trial(context) do
    journal = %{
      phase: :rebooting,
      release: release(),
      previous_uuid: "old",
      source_connection: "connection-old",
      source_boot_id: "boot-old"
    }

    path = NervesGate.Firmware.Artifact.verified_path(context.root, release())
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, :binary.copy(<<0>>, release().size))
    :ok = Persistence.save(context.root, journal)
  end

  defp candidate_boot(agent) do
    Agent.update(agent, fn state ->
      %{state | report: report("2.0.0", "new", :unvalidated, "b", "b")}
    end)
  end

  defp previous_boot(agent) do
    Agent.update(agent, fn state ->
      %{state | report: report("1.0.0", "old", :validated, "a", "a")}
    end)
  end

  defp report(version, uuid, validation, active, next) do
    %{
      supported: true,
      automatic_fallback: true,
      current: %{
        product: "nerves_gate",
        system: "test_system",
        platform: "test",
        architecture: "x86_64",
        version: version,
        uuid: uuid,
        vcs_identifier: if(uuid == "old", do: "old-revision", else: "new-revision"),
        slot: active
      },
      validation: validation,
      active_slot: active,
      next_slot: next
    }
  end

  defp release do
    %Release{
      id: "new",
      version: "2.0.0",
      uuid: "new",
      product: "nerves_gate",
      system: "test_system",
      platform: "test",
      architecture: "x86_64",
      vcs_identifier: "new-revision",
      artifact: "nerves_gate.fw",
      asset_url: "https://example.invalid/nerves_gate.fw",
      size: 1024,
      sha256: String.duplicate("0", 64)
    }
  end

  defp healthy do
    %{
      device_state: :ok,
      storage: :ok,
      configuration: :ok,
      internet: :ok,
      tailnet: :ok,
      alarms: :ok
    }
  end

  defp await_state(machine, expected, attempts \\ 100) do
    case Diagnostics.state(machine) do
      %Finitomata.State{current: ^expected} ->
        :ok

      _state when attempts > 0 ->
        Process.sleep(20)
        await_state(machine, expected, attempts - 1)

      state ->
        flunk("expected firmware state #{expected}, got #{inspect(state)}")
    end
  end

  defp await_confirmable(machine, attempts \\ 150) do
    if Firmware.status(machine).trial.confirmable do
      :ok
    else
      if attempts > 0 do
        Process.sleep(20)
        await_confirmable(machine, attempts - 1)
      else
        flunk("trial never became confirmable")
      end
    end
  end

  defp await_journal(root, phase, attempts \\ 100) do
    case Persistence.load(root) do
      {:ok, %{phase: ^phase}} = result ->
        result

      _other when attempts > 0 ->
        Process.sleep(20)
        await_journal(root, phase, attempts - 1)

      other ->
        flunk("expected #{phase} journal, got #{inspect(other)}")
    end
  end
end

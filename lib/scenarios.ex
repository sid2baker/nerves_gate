defmodule Scenarios do
  @moduledoc """
  One catalogue and requirements/execution boundary for owned-device scenarios.

  Owners provide a running target and hold its reservation through preparation,
  execution and cleanup. The default preparation does nothing: running a portable
  scenario never implicitly resets disks, changes wiring or configures a device.
  Requirements are checked before preparation. Unsupported resources/fixture
  controls skip a scenario; missing declared hardware, an unreachable device or a
  broken control fails it.
  """
  alias Scenarios.Device, as: Device

  @modules [
    Scenarios.Cases.AlarmRecovery,
    Scenarios.Cases.SdPlugins,
    Scenarios.Cases.Plugins,
    Scenarios.Cases.CableCycles,
    Scenarios.Cases.CableLoss,
    Scenarios.Cases.Churn,
    Scenarios.Cases.Concurrent,
    Scenarios.Cases.ConfirmedReboot,
    Scenarios.Cases.DependencyRestart,
    Scenarios.Cases.Firewall,
    Scenarios.Cases.FirmwareUpgrade,
    Scenarios.Cases.Freeze,
    Scenarios.Cases.FrontendAssets,
    Scenarios.Cases.Hotplug,
    Scenarios.Cases.Internet,
    Scenarios.Cases.InvalidConfiguration,
    Scenarios.Cases.InvalidTrialIds,
    Scenarios.Cases.Latency,
    Scenarios.Cases.Loss,
    Scenarios.Cases.MissingTrialNic,
    Scenarios.Cases.MultiDevice,
    Scenarios.Cases.PluginLan,
    Scenarios.Cases.PowerSaved,
    Scenarios.Cases.PowerTrial,
    Scenarios.Cases.ProcessChaos,
    Scenarios.Cases.ProcessCrash,
    Scenarios.Cases.ProjectionStream,
    Scenarios.Cases.PublicStatus,
    Scenarios.Cases.QemuSdk,
    Scenarios.Cases.QemuStatus,
    Scenarios.Cases.ReceiveStall,
    Scenarios.Cases.RestartIntensity,
    Scenarios.Cases.Sdk,
    Scenarios.Cases.SshAccess,
    Scenarios.Cases.Storage,
    Scenarios.Cases.StorageReboot,
    Scenarios.Cases.SystemArtifact,
    Scenarios.Cases.TailscaleAuth,
    Scenarios.Cases.TailscaleLogin,
    Scenarios.Cases.TestBench,
    Scenarios.Cases.Topology,
    Scenarios.Cases.TrialExpiry,
    Scenarios.Cases.TrialFault,
    Scenarios.Cases.TrialReboot
  ]

  def all do
    scenarios = Enum.map(@modules, &describe/1)
    ids = Enum.map(scenarios, & &1.id)
    if ids != Enum.uniq(ids), do: raise(ArgumentError, "Duplicate scenario IDs")
    Enum.sort_by(scenarios, & &1.id)
  end

  @doc "Operator-attended checks for physical gateways; run one at a time as a job."
  def physical do
    Enum.map(
      [
        Scenarios.Cases.HardwareReadiness,
        Scenarios.Cases.HardwareBackup,
        Scenarios.Cases.ButtonReboot
      ],
      &describe/1
    )
  end

  def select(selection) do
    Enum.filter(all(), &(&1.id == selection or (selection == "all" and not &1.opt_in)))
  end

  def describe(module) do
    spec = module.spec()
    requires = Map.fetch!(spec, :requires)

    unless Enum.sort(Map.keys(requires)) == [:device, :fixture] and
             is_list(requires.device) and is_list(requires.fixture) and
             Enum.all?(requires.device, &(&1 in [:ethernet, :cellular, :can, :rs485])) and
             Enum.all?(
               requires.fixture,
               &(&1 in [
                   :qemu,
                   :ethernet_link,
                   :reboot,
                   :power_cycle,
                   :physical
                 ])
             ),
           do: raise(ArgumentError, "Invalid requirements for #{inspect(module)}")

    %{
      id: module |> Module.split() |> List.last() |> Macro.underscore(),
      module: module,
      name: spec.name,
      requires: Map.fetch!(spec, :requires),
      fresh_disk: Map.get(spec, :fresh_disk, false),
      all: spec[:devices] == :all,
      opt_in: spec[:opt_in] == true
    }
  end

  def run(scenario, context, prepare \\ fn -> :ok end)

  def run(module, context, prepare) when is_atom(module),
    do: run(describe(module), context, prepare)

  def run(scenario, %{device: device} = context, prepare) do
    with :ok <-
           requirements(scenario.requires, %{fixture: Device.fixture_capabilities(device)}, [
             :fixture
           ]),
         :ok <- device_requirements(scenario.requires, device) do
      :ok = prepare.()
      scenario.module.run(context)
      %{status: :passed, detail: "OK"}
    else
      {:skip, reason} -> %{status: :skipped, detail: reason}
    end
  rescue
    error in ExUnit.AssertionError ->
      %{status: :failed, detail: Exception.message(error) |> String.trim()}

    # Assertions and RPC errors are failures, not unsupported hardware. Exits
    # propagate to the owner: a control call may have an unknown outcome.
    error ->
      %{status: :failed, detail: Exception.format(:error, error, __STACKTRACE__)}
  end

  @doc "Pure requirement matching, also used by bench owners before preparation."
  def requirements(required, available, kinds \\ [:device, :fixture]) do
    missing =
      for kind <- kinds,
          capability <- Map.get(required, kind, []),
          capability not in Map.get(available, kind, []),
          do: "#{kind}:#{capability}"

    if missing == [], do: :ok, else: {:skip, "Missing requirements: " <> Enum.join(missing, ", ")}
  end

  defp device_requirements(required, device) do
    if Map.get(required, :device, []) == [] do
      :ok
    else
      status = Device.status(device)

      if status == nil or not status.device.available,
        do: raise("Device unavailable while checking scenario requirements")

      with :ok <- requirements(required, %{device: Device.resources(status)}, [:device]) do
        Device.assert_present(status, required.device)
      end
    end
  end

  @doc "Skipped rows never count as passes; an entirely skipped run stays skipped."
  def result(rows) do
    cond do
      Enum.any?(rows, &(&1.status not in [:passed, :skipped])) -> :failed
      Enum.any?(rows, &(&1.status == :passed)) -> :passed
      true -> :skipped
    end
  end
end

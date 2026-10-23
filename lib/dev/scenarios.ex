defmodule Dev.Scenarios do
  @moduledoc """
  Portable platform-contract scenarios and their execution boundary.

  Owners provide a running target and hold its reservation through preparation,
  execution and cleanup. The default preparation does nothing: running a portable
  scenario never implicitly resets disks, changes wiring or configures a device.
  Requirements are checked before preparation. Unsupported resources/fixture
  controls skip a scenario; missing declared hardware, an unreachable device or a
  broken control fails it.
  """
  alias Dev.TestDevice, as: Device

  @modules [
    Dev.Scenarios.CableLoss,
    Dev.Scenarios.InvalidConfiguration,
    Dev.Scenarios.InvalidTrialIds,
    Dev.Scenarios.PublicStatus,
    Dev.Scenarios.Sdk
  ]

  def all, do: Enum.map(@modules, &describe/1)

  def describe(module) do
    spec = module.spec()

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
    # Assertions and RPC errors are failures, not unsupported hardware. Exits
    # propagate to the owner: a control call may have an unknown outcome.
    error -> %{status: :failed, detail: Exception.format(:error, error, __STACKTRACE__)}
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

      if status == nil or not status.backend.available,
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

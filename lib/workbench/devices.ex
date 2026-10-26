defmodule Workbench.Devices do
  @moduledoc "Read-only device directory. Only simulator-owned inventory receives the simulated kind."

  def list(bench, discovery) do
    physical =
      Enum.map(discovery.devices, fn device ->
        %{
          name: name(device),
          address: device.address,
          kind: :physical,
          target: device.target,
          version: device.version,
          status:
            cond do
              get_in(device, [:info_read, :status]) == :reading -> "Reading information…"
              get_in(device, [:info_read, :status]) == :failed -> "SSH information unavailable"
              device[:identity] -> "SSH identity read"
              device[:usb_info] -> "USB information read"
              true -> "Unverified"
            end,
          info_read: device[:info_read],
          source: device.source,
          url: device.url,
          path: physical_path(device.address)
        }
      end)

    simulated =
      Enum.map(bench.lifecycle.devices, fn config ->
        running = bench.devices[config.id]

        %{
          name: to_string(config.id),
          address: config.address,
          kind: :simulated,
          target: "x86_64",
          version: nil,
          status: simulated_status(bench, config.id),
          source: :simulator,
          url: if(running, do: running.ui),
          path: "/devices/#{config.id}"
        }
      end)

    Enum.sort_by(physical ++ simulated, &String.downcase(&1.name))
  end

  def filter(devices, kind, query) do
    query = query |> String.trim() |> String.downcase()

    Enum.filter(devices, fn device ->
      (kind == "all" or to_string(device.kind) == kind) and
        Enum.any?([device.name, device.address, device.target, device.version], fn value ->
          String.contains?(String.downcase(value || ""), query)
        end)
    end)
  end

  def needs_info?(device),
    do: is_nil(device[:identity]) and is_nil(device[:usb_info]) and is_nil(device[:info_read])

  def read_info!(address) do
    identity = Workbench.DeviceSSH.read_device!(address)
    :ok = Workbench.LANDiscovery.record_identity(address, identity)
    "Device information read over verified SSH. No firmware sent."
  end

  def name(%{source: :manual, address: address}), do: address
  def name(device), do: device.name || device.address

  def physical_path(address), do: "/devices/physical/#{URI.encode_www_form(address)}"

  def simulated_status(bench, id) do
    case bench.devices[id] do
      nil ->
        Map.get(bench.lifecycle, :progress, %{})[id] ||
          String.capitalize(to_string(bench.lifecycle.status))

      %{blocked: true} ->
        "Blocked · Reset required"

      %{owner: :manual} ->
        "Manual control"

      %{owner: nil} ->
        "Running"

      %{owner: run} ->
        "Run ##{run}"
    end
  end
end

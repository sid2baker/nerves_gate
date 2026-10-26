defmodule NervesGate.System do
  @moduledoc "Sanitized firmware and runtime identity, independent of device service availability."

  def info do
    %{
      firmware: Application.spec(:nerves_gate, :vsn) |> to_string(),
      source_revision: Nerves.Runtime.KV.get_active("nerves_fw_vcs_identifier"),
      target: Application.fetch_env!(:nerves_gate, :target) |> to_string(),
      node: Node.self(),
      elixir: System.version(),
      otp: System.otp_release()
    }
  end

  @doc "Bounded, credential-free physical maintenance identity."
  def maintenance_info do
    info = info()

    %{
      target: info.target,
      version: info.firmware,
      source_revision: info.source_revision,
      platform: Nerves.Runtime.KV.get_active("nerves_fw_platform"),
      architecture: Nerves.Runtime.KV.get_active("nerves_fw_architecture"),
      product: Nerves.Runtime.KV.get_active("nerves_fw_product"),
      serial: Nerves.Runtime.serial_number()
    }
  end

  @doc "Sanitized read-only readiness; never includes configuration or credentials."
  def hardware_info do
    status = NervesGate.status()
    internet = status.connections.internet

    selected =
      selected_source(internet.selected, get_in(status, [:network, :observed, :cellular, :name]))

    maintenance_info()
    |> Map.merge(%{
      boot_id: File.read!("/proc/sys/kernel/random/boot_id") |> String.trim(),
      firmware_validated:
        Nerves.Runtime.firmware_validation_status() == :validated and
          :heart.get_callback() == :none,
      available: status.device.available,
      ready:
        status.network.desired != nil and
          NervesGate.Network.ready?(status.network.observed, status.network.desired),
      pending: status.network.pending != nil,
      recovering: status.network.recovering,
      internet:
        internet
        |> Map.take([:mode, :ethernet, :cellular, :health])
        |> Map.put(:selected, selected)
        |> Map.put(:ethernet_link, ethernet_link(status.connections.ports)),
      cellular: Map.take(status.cellular, [:supported, :present, :enabled, :sim, :registration])
    })
  end

  defp selected_source(nil, _), do: nil
  defp selected_source(name, name), do: "cellular"
  defp selected_source(_, _), do: "ethernet"

  defp ethernet_link(ports) do
    case Enum.filter(ports, &(&1.role == "internet")) do
      [] -> nil
      ports -> Enum.any?(ports, &(&1.link == true))
    end
  end
end

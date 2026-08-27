defmodule NervesGate.Firmware.Platform.Host do
  @moduledoc "Safe unsupported platform used for host development and unit tests."

  @behaviour NervesGate.Firmware.Platform

  @impl true
  def status(_options) do
    {:ok,
     %{
       supported: false,
       automatic_fallback: false,
       current: %{
         product: "nerves_gate",
         system: "host",
         platform: "host",
         architecture: :erlang.system_info(:system_architecture) |> to_string(),
         version: Application.spec(:nerves_gate, :vsn) |> to_string(),
         uuid: "host"
       },
       validation: :unknown,
       active_slot: nil,
       next_slot: nil
     }}
  end

  @impl true
  def install_verified(_path, _release, _options), do: {:error, :firmware_updates_unsupported}

  @impl true
  def validate(_options), do: {:error, :firmware_updates_unsupported}

  @impl true
  def synchronize(_options), do: {:error, :firmware_updates_unsupported}

  @impl true
  def revert(_options), do: {:error, :firmware_updates_unsupported}

  @impl true
  def reboot(_options), do: {:error, :firmware_updates_unsupported}
end

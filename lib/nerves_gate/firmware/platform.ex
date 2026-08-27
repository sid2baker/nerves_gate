defmodule NervesGate.Firmware.Platform do
  @moduledoc "Boot-system contract required by the platform-independent firmware workflow."

  alias NervesGate.Firmware.Release

  @type report :: %{
          supported: boolean(),
          automatic_fallback: boolean(),
          current: map(),
          validation: :validated | :unvalidated | :unknown,
          active_slot: String.t() | nil,
          next_slot: String.t() | nil
        }

  @callback status(keyword()) :: {:ok, report()} | {:error, term()}
  @callback install_verified(Path.t(), Release.t(), keyword()) :: :ok | {:error, term()}
  @callback validate(keyword()) :: :ok | {:error, term()}
  @callback synchronize(keyword()) :: :ok | {:error, term()}
  @callback revert(keyword()) :: :ok | {:error, term()}
  @callback reboot(keyword()) :: no_return() | :ok | {:error, term()}
end

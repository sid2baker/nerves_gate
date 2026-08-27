defmodule NervesGate.Firmware.Status do
  @moduledoc "Secret-free public firmware lifecycle state."

  @type validation :: :validated | :trial | :unknown | :unsupported
  @type phase ::
          :booting
          | :unsupported
          | :idle
          | :checking
          | :downloading
          | :verifying
          | :ready
          | :preflight
          | :installing
          | :rebooting
          | :trial
          | :validating
          | :rolling_back
          | :failed

  @type t :: %__MODULE__{
          supported: boolean(),
          phase: phase(),
          current: map(),
          validation: validation(),
          available: map() | nil,
          artifact: map() | nil,
          progress: non_neg_integer() | nil,
          health: map(),
          trial: map() | nil,
          last_checked_at: String.t() | nil,
          last_error: atom() | nil
        }

  @enforce_keys [:supported, :phase, :current, :validation]
  defstruct supported: false,
            phase: :unsupported,
            current: %{},
            validation: :unsupported,
            available: nil,
            artifact: nil,
            progress: nil,
            health: %{},
            trial: nil,
            last_checked_at: nil,
            last_error: nil
end

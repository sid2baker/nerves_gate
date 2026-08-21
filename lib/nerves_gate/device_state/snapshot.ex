defmodule NervesGate.DeviceState.Snapshot do
  @moduledoc "Atomic join snapshot returned by an authoritative device-state server."

  alias NervesGate.DeviceState.Public

  @enforce_keys [:boot_id, :revision, :data]
  defstruct [:boot_id, :revision, :data]

  @type t :: %__MODULE__{
          boot_id: String.t(),
          revision: non_neg_integer(),
          data: Public.t()
        }
end

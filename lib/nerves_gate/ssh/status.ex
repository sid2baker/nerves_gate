defmodule NervesGate.SSH.Status do
  @moduledoc "Secret-free public SSH lifecycle state."

  @enforce_keys [:enabled, :state, :address, :port]
  defstruct [:enabled, :state, :address, :port]

  @type t :: %__MODULE__{
          enabled: boolean(),
          state: :disabled | :blocked | :reconciling | :listening | :backoff,
          address: String.t() | nil,
          port: 22
        }
end

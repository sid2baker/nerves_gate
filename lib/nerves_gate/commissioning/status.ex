defmodule NervesGate.Commissioning.Status do
  @moduledoc "Secret-free public commissioning-access state."

  @enforce_keys [:state, :active, :mode]
  defstruct [:state, :active, :mode]

  @type t :: %__MODULE__{
          state: :disabled | :active | :waiting | :backoff,
          active: [map()],
          mode: :disabled | :commissioning
        }
end

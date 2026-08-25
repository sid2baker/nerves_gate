defmodule NervesGate.SubnetRouter.Status do
  @moduledoc "Secret-free public subnet-router state."

  @enforce_keys [:enabled, :routes, :state, :observed]
  defstruct [:enabled, :routes, :state, :observed]

  @type t :: %__MODULE__{
          enabled: boolean(),
          routes: [String.t()],
          state: :disabled | :blocked | :applying | :awaiting_approval | :active | :backoff,
          observed: map()
        }
end

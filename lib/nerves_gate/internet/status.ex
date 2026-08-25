defmodule NervesGate.Internet.Status do
  @moduledoc "Secret-free public uplink reality; private observation phases are excluded."

  @enforce_keys [:state, :interface, :online, :ready, :reason, :checks]
  defstruct [:state, :interface, :online, :ready, :reason, :checks]

  @type t :: %__MODULE__{
          state: :unconfigured | :applying | :online | :offline | :backoff,
          interface: String.t() | nil,
          online: boolean(),
          ready: boolean(),
          reason: atom() | nil,
          checks: map()
        }
end

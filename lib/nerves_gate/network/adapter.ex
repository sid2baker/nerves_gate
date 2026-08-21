defmodule NervesGate.Network.Adapter do
  @moduledoc "Boundary for target network configuration and host simulations."

  alias NervesGate.Network.Config

  @callback configure_uplink(Config.t()) :: :ok | {:error, term()}
  @callback clear(String.t()) :: :ok | {:error, term()}
  @callback configure_commissioning(String.t(), map()) :: :ok | {:error, term()}
  @callback snapshot(String.t()) :: map()
end

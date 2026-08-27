defmodule NervesGate.Firmware.ReleaseSource do
  @moduledoc "Discovery boundary for published firmware releases."

  alias NervesGate.Firmware.Release

  @callback latest(current :: map(), options :: keyword()) ::
              {:ok, Release.t() | nil} | {:error, term()}
end

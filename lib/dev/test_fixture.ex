defmodule Dev.TestFixture do
  @moduledoc """
  Host-side controls for an explicitly owned test bench, never an application API.

  A target may supply `fixture: {module, handle}`. The owner must authorize the
  bench and reserve its devices before running scenarios. No fixture is selected
  from a node name, board model or discovered hardware. Physical benches must
  provide their own authorized controls; this project currently supplies QEMU.

  Advertise only implemented controls. Return errors only for known outcomes;
  an uncertain outcome must exit and reject further controls, including cleanup.
  The owner must retain the reservation and block the target until recovery.
  """

  @callback capabilities(term()) :: [atom()]
  @callback control(term(), atom(), list()) :: term()
end

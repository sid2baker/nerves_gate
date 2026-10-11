defmodule NervesGate do
  @moduledoc """
  Local management for a two-port Ethernet gateway.

  Start with `NervesGate.Device.projection/0` and `NervesGate.Device.dispatch/3`.
  The supported actions and their routing are in `NervesGate.Device.Actions`.
  """
  def target, do: Application.fetch_env!(:nerves_gate, :target)
  def version, do: Application.spec(:nerves_gate, :vsn) |> to_string()
end

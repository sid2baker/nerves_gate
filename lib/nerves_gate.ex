defmodule NervesGate do
  @moduledoc """
  Local management for a two-port Ethernet gateway.

  Start with `NervesGate.Device.projection/0` and `NervesGate.Device.dispatch/3`.
  Device is stateless; domain Jido Actions and Agents own command orchestration.
  """
  def target, do: Application.fetch_env!(:nerves_gate, :target)
  def version, do: Application.spec(:nerves_gate, :vsn) |> to_string()
end

defmodule NervesGate do
  @moduledoc "Local management for a two-port Ethernet gateway."
  def target, do: Application.fetch_env!(:nerves_gate, :target)
  def version, do: Application.spec(:nerves_gate, :vsn) |> to_string()
end

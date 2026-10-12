defmodule NervesGate.Indicators.Policy do
  @moduledoc "Pure LED policy. Slow is 1 Hz; fast is 4 Hz. Unknown is never shown as healthy."

  def normal(remote, internet, alarms) do
    %{run: :solid, user1: remote_pattern(remote, internet, alarms), user2: alarm_pattern(alarms)}
  end

  def remote_pattern(%{operation: "disconnect"}, _, _), do: :off
  def remote_pattern(%{operation: "connect"}, _, _), do: :slow

  def remote_pattern(%{available: true, auth_state: auth}, _, _)
      when auth in ["stopped", "needs_login"],
      do: :off

  def remote_pattern(%{available: true, auth_state: auth}, _, _)
      when auth in ["authenticating", "needs_approval"],
      do: :slow

  def remote_pattern(_, _, %{connection: true}), do: :fast

  def remote_pattern(
        %{available: true, state: "online", auth_state: "authenticated", health: []},
        true,
        %{connection: false}
      ),
      do: :solid

  def remote_pattern(_, _, _), do: :slow

  def alarm_pattern(%{severity: :error}), do: :fast
  def alarm_pattern(%{severity: :none}), do: :off
  def alarm_pattern(_), do: :slow

  def override(_, feedback) when feedback in [:reset, :identify] do
    pattern = if feedback == :reset, do: :fast, else: :slow
    Map.new([:run, :user1, :user2], &{&1, pattern})
  end

  def override(patterns, :warning), do: %{patterns | user2: :fast}
  def override(patterns, :reboot), do: %{patterns | run: :slow}
  def override(patterns, :normal), do: patterns

  def value(:off, _), do: 0
  def value(:solid, _), do: 1
  def value(:slow, now), do: phase(now, 500)
  def value(:fast, now), do: phase(now, 125)

  defp phase(now, half_period), do: Integer.mod(Integer.floor_div(now, half_period), 2)
end

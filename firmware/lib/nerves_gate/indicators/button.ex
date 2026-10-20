defmodule NervesGate.Indicators.Button do
  @moduledoc "Pure release-only gestures. A release is required after startup or input loss."
  @debounce_ms 50

  def new, do: %{pressed_at: nil, released_at: nil}

  def event(0, now, state) do
    action = if state.pressed_at, do: action(now - state.pressed_at)
    {%{pressed_at: nil, released_at: now}, action}
  end

  def event(1, now, %{pressed_at: nil, released_at: released} = state)
      when is_integer(released) and now - released >= @debounce_ms,
      do: {%{state | pressed_at: now}, nil}

  def event(1, _, %{pressed_at: pressed} = state) when is_integer(pressed),
    do: {state, nil}

  def event(2, _, state), do: {state, nil}
  def event(_, _, _), do: {new(), nil}

  def feedback(%{pressed_at: nil}, _), do: :normal
  def feedback(%{pressed_at: pressed}, now) when now - pressed >= 30_000, do: :reset
  def feedback(%{pressed_at: pressed}, now) when now - pressed >= 25_000, do: :warning
  def feedback(%{pressed_at: pressed}, now) when now - pressed >= 5_000, do: :reboot
  def feedback(_, _), do: :normal

  defp action(ms) when ms < @debounce_ms, do: nil
  defp action(ms) when ms < 2_000, do: :identify
  defp action(ms) when ms < 5_000, do: nil
  defp action(ms) when ms < 30_000, do: :reboot
  defp action(_), do: :factory_reset
end

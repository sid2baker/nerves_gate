defmodule NervesGate.Backoff do
  @moduledoc "Bounded exponential backoff with jitter."

  @spec next(pos_integer(), pos_integer()) :: {pos_integer(), pos_integer()}
  def next(current, maximum) when current > 0 and maximum >= current do
    upper = min(maximum, current * 2)
    jittered = current + :rand.uniform(max(1, upper - current)) - 1
    {jittered, upper}
  end
end

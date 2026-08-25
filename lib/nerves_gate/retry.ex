defmodule NervesGate.Retry do
  @moduledoc false

  @spec due?(integer() | nil) :: boolean()
  def due?(nil), do: true
  def due?(retry_at), do: now() >= retry_at

  @spec now() :: integer()
  def now, do: System.monotonic_time(:millisecond)

  @spec public_error(term()) :: atom()
  def public_error(reason) when is_atom(reason), do: reason
  def public_error(_reason), do: :operation_failed

  @spec next(pos_integer(), pos_integer()) :: {pos_integer(), pos_integer()}
  def next(current, maximum) when current > 0 and maximum >= current do
    upper = min(maximum, current * 2)
    jittered = current + :rand.uniform(max(1, upper - current)) - 1
    {jittered, upper}
  end
end

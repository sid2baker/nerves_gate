defmodule NervesGate.Reconciliation do
  @moduledoc """
  Common retry metadata and timing policy for resource reconcilers.

  The module returns retry fields only. Each owner remains responsible for its
  domain phase and blocking reason instead of handing over its complete state.
  """

  @type retry_fields :: %{
          attempt: non_neg_integer(),
          last_error: term() | nil,
          retry_at: integer() | nil
        }

  @spec failed(non_neg_integer(), non_neg_integer(), term()) :: retry_fields()
  def failed(attempt, delay, error) do
    %{
      attempt: attempt + 1,
      last_error: error,
      retry_at: after_ms(delay)
    }
  end

  @spec converged() :: retry_fields()
  def converged, do: %{attempt: 0, last_error: nil, retry_at: nil}

  @spec due?(integer() | nil) :: boolean()
  def due?(nil), do: true
  def due?(retry_at), do: System.monotonic_time(:millisecond) >= retry_at

  @spec after_ms(non_neg_integer()) :: integer()
  def after_ms(delay), do: System.monotonic_time(:millisecond) + delay

  @spec public_error(term()) :: atom()
  def public_error(reason) when is_atom(reason), do: reason
  def public_error(_reason), do: :operation_failed

  @spec next_delay(pos_integer(), pos_integer()) :: {pos_integer(), pos_integer()}
  def next_delay(current, maximum) when current > 0 and maximum >= current do
    upper = min(maximum, current * 2)
    jittered = current + :rand.uniform(max(1, upper - current)) - 1
    {jittered, upper}
  end
end

defmodule NervesGate.Gateway.Configuration.Context do
  @moduledoc "Pure public projections and timing helpers for staged gateway configuration."

  alias NervesGate.Gateway.Settings
  alias NervesGate.Internet.Config

  @spec public(map()) :: map()
  def public(payload) do
    %{
      configured: payload.current["configured"],
      current: Settings.public(payload.current),
      pending: if(payload.pending, do: public_pending(payload.pending)),
      last_error: public_error(payload.last_error)
    }
  end

  @spec public_pending(map()) :: map()
  def public_pending(pending) do
    %{
      id: pending.id,
      phase: pending.phase,
      scope: Map.get(pending, :scope, :complete),
      candidate: Settings.public(pending.candidate),
      remaining_seconds: remaining_seconds(pending.deadline)
    }
  end

  defp public_error(nil), do: nil
  defp public_error(reason) when is_atom(reason), do: reason
  defp public_error({reason, _private}) when is_atom(reason), do: reason
  defp public_error(_private), do: :configuration_failed

  @spec remaining_seconds(integer() | nil) :: non_neg_integer() | nil
  def remaining_seconds(nil), do: nil

  def remaining_seconds(deadline) do
    max(0, div(deadline - System.monotonic_time(:millisecond) + 999, 1_000))
  end

  @spec active_interface(map()) :: String.t() | nil
  def active_interface(settings) do
    case Settings.internet(settings) do
      %Config{interface: interface} -> interface
      nil -> nil
    end
  end

  @spec tailnet_metadata(map(), map()) :: map()
  def tailnet_metadata(current, candidate) do
    %{
      "previous_profile_id" => Settings.tailnet_profile(current),
      "candidate_profile_id" => Settings.tailnet_profile(candidate)
    }
  end
end

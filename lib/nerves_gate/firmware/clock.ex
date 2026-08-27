defmodule NervesGate.Firmware.Clock do
  @moduledoc false

  @spec monotonic_ms() :: integer()
  def monotonic_ms, do: System.monotonic_time(:millisecond)

  @spec system_boot_id() :: String.t()
  def system_boot_id do
    case File.read("/proc/sys/kernel/random/boot_id") do
      {:ok, id} -> String.trim(id)
      {:error, _reason} -> "unknown-boot"
    end
  end

  @spec uptime_ms() :: non_neg_integer()
  def uptime_ms do
    with {:ok, contents} <- File.read("/proc/uptime"),
         [seconds | _rest] <- String.split(contents),
         {value, _remainder} <- Float.parse(seconds) do
      trunc(value * 1_000)
    else
      _unavailable ->
        {milliseconds, _since_last_call} = :erlang.statistics(:wall_clock)
        milliseconds
    end
  end
end

defmodule ModbusPlugin.Outputs do
  @moduledoc """
  `NervesGateSDK.Output` callbacks for one client connection. Each Desire becomes
  one serialized setter on the connection that owns the transport. Mapped outputs
  are repeatable coils/registers, so a failed or uncertain write is retried after
  the poll interval and a disagreeing readback asks for a rewrite. A released
  Desire holds the last value: nothing is written.
  """
  @behaviour NervesGateSDK.Output
  alias ModbusPlugin.Connection

  @impl true
  def apply(id, nil, state) do
    Connection.forget(state.connection, mapping_id(state, id))
    {:applied, state}
  end

  def apply(id, value, state) do
    outcome =
      case Connection.write(state.connection, mapping_id(state, id), value, state.timeout) do
        :ok -> :applied
        {:error, :timeout} -> :unknown
        {:error, reason} -> {:failed, reason}
      end

    if outcome != :applied, do: NervesGateSDK.Output.reapply_after(id, state.interval)
    {outcome, state}
  end

  # Local output IDs are "<connection>.<mapping>"; connection IDs contain no dots.
  defp mapping_id(state, id), do: String.replace_prefix(id, state.prefix, "")
end

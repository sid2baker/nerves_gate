defmodule NervesGate.DeviceState.Signal.Changing do
  @moduledoc "Raw condition indicating that a complete settings candidate is active."
  def description, do: "Configuration change in progress"
end

defmodule NervesGate.DeviceState.Alarms do
  @moduledoc "Owns DeviceState signals used to inhibit expected operational alarms."

  alias NervesGate.Alarms
  alias NervesGate.DeviceState.Signal

  def managed_alarms, do: []
  def public_alarms, do: []
  def alarm_levels, do: %{Signal.Changing => :debug}
  def remedies, do: []

  @spec changing(boolean()) :: :ok
  def changing(active) do
    Alarms.report_sync(Signal.Changing, active, Signal.Changing.description())
  end
end

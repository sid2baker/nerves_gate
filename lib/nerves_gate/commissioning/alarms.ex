defmodule NervesGate.Commissioning.Alarm.Required do
  @moduledoc "The device needs local commissioning."
  def description, do: "Device commissioning is required"
end

defmodule NervesGate.Commissioning.Alarm.Unavailable do
  @moduledoc "No local commissioning interface could be enabled."
  def description, do: "No local commissioning interface is available"
end

defmodule NervesGate.Commissioning.Alarms do
  @moduledoc "Owns independent commissioning alarm conditions."

  alias NervesGate.Alarms
  alias NervesGate.Commissioning.Alarm

  def required(true), do: Alarms.set(Alarm.Required, Alarm.Required.description())
  def required(false), do: Alarms.clear(Alarm.Required)

  def unavailable(true), do: Alarms.set(Alarm.Unavailable, Alarm.Unavailable.description())
  def unavailable(false), do: Alarms.clear(Alarm.Unavailable)
end

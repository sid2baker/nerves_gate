defmodule NervesGate.SubnetRouter.Alarm.Unavailable do
  @moduledoc "The desired Tailnet subnet routes could not be applied."
  def description, do: "Subnet router configuration could not be applied"
end

defmodule NervesGate.SubnetRouter.Alarms do
  @moduledoc "Owns the independent, noncritical subnet-router alarm."

  alias NervesGate.Alarms
  alias NervesGate.SubnetRouter.Alarm.Unavailable

  @spec failure(boolean()) :: :ok
  def failure(true), do: Alarms.set(Unavailable, Unavailable.description())
  def failure(false), do: Alarms.clear(Unavailable)
end

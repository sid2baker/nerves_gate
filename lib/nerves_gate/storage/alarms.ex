defmodule NervesGate.Storage.Alarm.Failure do
  @moduledoc "Persistent storage is unavailable or corrupt."
  def description, do: "Persistent storage is unavailable or corrupt"
end

defmodule NervesGate.Storage.Alarms do
  @moduledoc "Owns the independent persistent-storage alarm."

  alias NervesGate.Alarms
  alias NervesGate.Storage.Alarm.Failure

  def failure(true), do: Alarms.set(Failure, Failure.description())
  def failure(false), do: Alarms.clear(Failure)
end

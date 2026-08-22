defmodule NervesGate.Settings.Signal.InternetChanging do
  @moduledoc false
  def description, do: "Internet settings change in progress"
end

defmodule NervesGate.Settings.Signal.TailnetChanging do
  @moduledoc false
  def description, do: "Tailnet settings change in progress"
end

defmodule NervesGate.Settings.Signal.ClusterChanging do
  @moduledoc false
  def description, do: "Cluster settings change in progress"
end

defmodule NervesGate.Settings.Maintenance do
  @moduledoc "Inhibits expected dependency alarms during one guarded settings change."

  alias NervesGate.Alarms
  alias NervesGate.Settings.Signal

  @key {__MODULE__, :layers}
  @all [:internet, :tailnet, :cluster]

  @spec begin(:internet | :tailnet | :cluster) :: :ok
  def begin(:internet), do: put(@all)
  def begin(:tailnet), do: put([:tailnet, :cluster])
  def begin(:cluster), do: put([:cluster])

  @spec clear() :: :ok
  def clear, do: put([])

  @spec layers() :: [atom()]
  def layers, do: :persistent_term.get(@key, [])

  @spec active?(:internet | :tailnet | :cluster) :: boolean()
  def active?(layer), do: layer in layers()

  defp put(layers) do
    :persistent_term.put(@key, layers)

    Alarms.toggle(
      Signal.InternetChanging,
      :internet in layers,
      Signal.InternetChanging.description()
    )

    Alarms.toggle(
      Signal.TailnetChanging,
      :tailnet in layers,
      Signal.TailnetChanging.description()
    )

    Alarms.toggle(
      Signal.ClusterChanging,
      :cluster in layers,
      Signal.ClusterChanging.description()
    )
  end
end

defmodule NervesGate.Observations do
  @moduledoc """
  Ephemeral workflow properties. Firmware subsystem readings stay in VintageNet
  and Tailscaled's own tables. Subscriptions belong to the
  calling process and PropertyTable's Registry removes them on process death.
  """
  @table NervesGate.Properties

  def table, do: @table
  def workflow(domain, id), do: [domain, id]

  def put(path, value), do: PropertyTable.put(@table, path, value)

  @doc false
  def subscribe_runtime(server), do: server |> GenServer.call(:observations) |> subscribe()

  def subscribe(sources) do
    Enum.reduce_while(sources, :ok, fn {table, path}, :ok ->
      registry = PropertyTable.Supervisor.registry_name(table)

      if Process.whereis(registry) do
        # Registry subscriptions allow duplicates, so rebind this exact path.
        PropertyTable.unsubscribe(table, path)
        :ok = PropertyTable.subscribe(table, path)
        {:cont, :ok}
      else
        {:halt,
         {:error,
          %{
            code: "unavailable",
            message: "Network control is unavailable. Reconnect and read the current state."
          }}}
      end
    end)
  end
end

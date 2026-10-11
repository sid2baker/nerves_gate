defmodule NervesGate.Observations do
  @moduledoc """
  Ephemeral workflow and host-simulation properties. Firmware subsystem readings
  stay in VintageNet and Tailscale's own tables. Subscriptions belong to the
  calling process and PropertyTable's Registry removes them on process death.
  """
  @table NervesGate.Properties

  def table, do: @table
  def workflow(domain, id), do: [domain, id]
  def host(domain, server), do: ["host", domain, inspect(GenServer.whereis(server))]

  def put(path, value), do: PropertyTable.put(@table, path, value)

  def sources({module, context}) do
    if Code.ensure_loaded?(module) and function_exported?(module, :observations, 1),
      do: module.observations(context),
      else: []
  end

  @doc false
  def subscribe_runtime(server), do: server |> GenServer.call(:observations) |> subscribe()

  def subscribe(sources) do
    Enum.each(sources, fn {table, path} ->
      # Rebinding is idempotent, including after a subsystem table restart.
      try do
        PropertyTable.unsubscribe(table, path)
        PropertyTable.subscribe(table, path)
      rescue
        ArgumentError -> :ok
      end
    end)

    :ok
  end
end

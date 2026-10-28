defmodule ModbusPlugin.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    Supervisor.start_link(
      [
        {Registry, keys: :unique, name: ModbusPlugin.Registry},
        {DynamicSupervisor, name: ModbusPlugin.Connections, strategy: :one_for_one},
        ModbusPlugin.Command,
        ModbusPlugin
      ],
      strategy: :one_for_all,
      name: ModbusPlugin.Supervisor
    )
  end
end

defmodule IotrouterExpansion.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    Supervisor.start_link(
      [
        {DynamicSupervisor, name: IotrouterExpansion.Buses, strategy: :one_for_one},
        IotrouterExpansion
      ],
      strategy: :one_for_all,
      name: IotrouterExpansion.Supervisor
    )
  end
end

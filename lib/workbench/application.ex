defmodule Workbench.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    Supervisor.start_link(
      [{Task.Supervisor, name: Workbench.Tasks}, Workbench.Plugins],
      strategy: :one_for_one,
      name: Workbench.Supervisor
    )
  end
end

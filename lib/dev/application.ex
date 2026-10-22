defmodule Dev.Application do
  @moduledoc false
  use Application

  def start(_, _) do
    Supervisor.start_link(
      [
        {Task.Supervisor, name: Dev.Tasks},
        Dev.Applications,
        Dev.Discovery,
        Dev.Operations
      ],
      strategy: :one_for_one,
      name: Dev.Supervisor
    )
  end
end

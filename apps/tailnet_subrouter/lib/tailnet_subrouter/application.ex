defmodule TailnetSubrouter.Application do
  use Application

  def start(_, _) do
    Supervisor.start_link([TailnetSubrouter],
      strategy: :one_for_one,
      name: TailnetSubrouter.Supervisor
    )
  end
end

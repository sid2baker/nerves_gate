defmodule Workbench.SessionServices do
  @moduledoc "Workbench services started only by the explicit session, never ordinary host tasks."
  use Supervisor

  def start_link(opts \\ []), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_) do
    Supervisor.init(
      [
        {Phoenix.PubSub, name: NervesGate.PubSub},
        Scenarios.Runner,
        WorkbenchWeb.Endpoint
      ],
      strategy: :rest_for_one
    )
  end
end

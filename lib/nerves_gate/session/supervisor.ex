defmodule NervesGate.Session.Supervisor do
  @moduledoc "Supervises disposable client sessions."

  use DynamicSupervisor

  alias NervesGate.Session

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    DynamicSupervisor.start_link(__MODULE__, options,
      name: Keyword.get(options, :name, __MODULE__)
    )
  end

  @spec start_session(pid(), keyword()) :: DynamicSupervisor.on_start_child()
  def start_session(client, options \\ []) when is_pid(client) do
    child = %{
      id: Session,
      start: {Session, :start_link, [[{:client, client} | options]]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, child)
  end

  @impl true
  def init(_options), do: DynamicSupervisor.init(strategy: :one_for_one)
end

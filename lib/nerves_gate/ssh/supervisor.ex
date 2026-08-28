defmodule NervesGate.SSH.Supervisor do
  @moduledoc "Supervises the SSH owner and its temporary listener process."

  use Supervisor

  alias NervesGate.SSH

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(options \\ []) do
    Supervisor.start_link(__MODULE__, options, name: Keyword.get(options, :name, __MODULE__))
  end

  @impl true
  def init(options) do
    children = [
      {DynamicSupervisor, name: NervesGate.SSH.DynamicSupervisor, strategy: :one_for_one},
      {SSH, options}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule NervesGate.Network do
  @moduledoc """
  LAN supervision and internal API. Clients call `NervesGate.network_*`.
  The runtime owns commands, workers and rollback; Jido decides USB auto-save.
  """
  use Supervisor
  alias NervesGate.Network.{Agent, Policy, Runtime}

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    id = inspect(self())

    children = [
      {Runtime, Keyword.put(opts, :id, id)},
      Supervisor.child_spec(
        {Jido.AgentServer,
         [
           agent: Agent.new!(id: id),
           jido: NervesGate.Jido,
           register: false,
           name: Runtime.agent_via(id),
           restart: :permanent,
           max_postponed_signals: 32
         ]},
        id: :agent
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def status(server \\ __MODULE__), do: Runtime.status(runtime(server))
  defdelegate validate(network), to: NervesGate.Config, as: :validate_network

  def propose(network, server \\ __MODULE__, access \\ nil),
    do: GenServer.call(runtime(server), {:propose, network, access}, 15_000)

  def scan(equipment, server \\ __MODULE__) do
    GenServer.call(runtime(server), {:scan, equipment}, 15_000)
  end

  def sharing(operation, params, server \\ __MODULE__),
    do: GenServer.call(runtime(server), {:sharing, operation, params}, 70_000)

  def confirm(id, server \\ __MODULE__) do
    GenServer.call(runtime(server), {:confirm, id}, 15_000)
  end

  def cancel(id, server \\ __MODULE__),
    do: GenServer.call(runtime(server), {:cancel, id}, 15_000)

  @doc "Subscribe before reading; subscriptions belong to the caller."
  def observe(server \\ __MODULE__),
    do: NervesGate.Observations.subscribe_runtime(runtime(server))

  defdelegate ready?(observed, network), to: Policy
  defdelegate conflicts(observed, network), to: Policy

  @doc false
  def runtime(server), do: GenServer.whereis(Runtime.via(instance_id(server)))
  @doc false
  def agent(server), do: GenServer.whereis(Runtime.agent_via(instance_id(server)))

  defp instance_id(server), do: inspect(GenServer.whereis(server))
end

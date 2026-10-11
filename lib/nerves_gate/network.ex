defmodule NervesGate.Network do
  @moduledoc """
  Public network commands and domain supervision. Jido coordinates commands;
  the independent runtime owns the journal, hardware worker and safety timer.
  Restart order ensures runtime recovery precedes a fresh agent.
  """
  use Supervisor
  alias NervesGate.Command
  alias NervesGate.Network.{Agent, Policy, Runtime}

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(opts) do
    id = Command.id()

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
           max_postponed_signals: 32,
           directive_timeout: 25_000
         ]},
        id: :agent
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def status(server \\ __MODULE__), do: Runtime.status(runtime(server))

  def validate(network, _server \\ __MODULE__) do
    with {:ok, %{outcome: result}} <-
           Jido.Exec.run(
             NervesGate.Network.Actions.Validate,
             %{network: network},
             %{agent_state: %{outcome: nil}},
             timeout: 5000
           ) do
      result
    end
  end

  def propose(network, server \\ __MODULE__, access \\ nil, expected_revision \\ nil) do
    Command.call(agent(server), "network.propose", %{network: network, id: Command.id()}, %{
      access: access,
      expected_revision: expected_revision
    })
  end

  def confirm(id, server \\ __MODULE__, expected_revision \\ nil),
    do:
      Command.call(agent(server), "network.confirm", %{id: id}, %{
        expected_revision: expected_revision
      })

  def cancel(id, server \\ __MODULE__, expected_revision \\ nil),
    do:
      Command.call(agent(server), "network.cancel", %{id: id}, %{
        expected_revision: expected_revision
      })

  @doc "Subscribe before reading; properties are owned by the caller's process lifecycle."
  def observe(server \\ __MODULE__) do
    NervesGate.Observations.subscribe_runtime(runtime(server))
  end

  defdelegate ready?(observed, network), to: Policy
  defdelegate conflicts(observed, network), to: Policy

  @doc false
  def runtime(server), do: Command.child(server, NervesGate.Network.Runtime)
  @doc false
  def agent(server), do: Command.child(server, :agent)
end

defmodule NervesGate.Remote do
  @moduledoc """
  Public Tailscale domain API. Commands use Jido Actions and return acceptance,
  not daemon completion. Observe status for the eventual result. The daemon
  remains authoritative; restarting this domain only observes it.
  """
  use Supervisor
  alias NervesGate.Command
  alias NervesGate.Remote.{Agent, Policy, Runtime}

  def start_link(opts \\ []),
    do: Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

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
           max_postponed_signals: 32
         ]},
        id: :agent
      )
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  def status(server \\ __MODULE__), do: Runtime.status(runtime(server))

  def command(operation, params, server \\ __MODULE__, expected_revision \\ nil) do
    if operation in [:connect, :configure, :disconnect] do
      Command.call(agent(server), "remote.#{operation}", %{params: params, id: Command.id()}, %{
        expected_revision: expected_revision
      })
    else
      Policy.validate(operation, params)
    end
  end

  def login_url(server \\ __MODULE__), do: Command.call(agent(server), "remote.login_url", %{})

  @doc "Subscribe to workflow and cached subsystem properties, never enrollment URLs."
  def observe(server \\ __MODULE__) do
    NervesGate.Observations.subscribe_runtime(runtime(server))
  end

  defdelegate unavailable(), to: Policy
  defdelegate validate(operation, params), to: Policy

  @doc false
  def runtime(server), do: Command.child(server, NervesGate.Remote.Runtime)
  @doc false
  def agent(server), do: Command.child(server, :agent)
end

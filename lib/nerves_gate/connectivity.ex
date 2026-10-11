defmodule NervesGate.Connectivity do
  @moduledoc "Supervised connectivity policy. Alarmist owns conditions; Jido owns bounded recheck coordination."
  alias NervesGate.Command
  alias NervesGate.Connectivity.Agent

  def start_link(opts \\ []) do
    agent =
      Agent.new!(id: Command.id(), state: %{monitoring: Keyword.get(opts, :monitoring, %{})})

    Jido.AgentServer.start_link(
      agent: agent,
      jido: NervesGate.Jido,
      register: false,
      name: Keyword.get(opts, :name, __MODULE__),
      restart: :permanent,
      max_postponed_signals: 32
    )
  end

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}
end

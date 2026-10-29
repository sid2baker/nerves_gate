defmodule NervesGate.IOFixture do
  @moduledoc """
  A real managed plugin activation, `io_fixture`, for I/O tests. Its supervised
  `Publisher`, `Handler` and `Other` processes run functions in their own PIDs and
  forward any other message to the test process as `{:plugin_hint, pid, message}`.
  """
  import ExUnit.Callbacks, only: [on_exit: 1]
  alias NervesGate.IO, as: GateIO
  alias NervesGate.Plugins.Owner
  alias NervesGateSDK.IO.{Evidence, InputDefinition, OutputDefinition}

  defmodule Child do
    @moduledoc false
    use GenServer
    def start_link({name, parent}), do: GenServer.start_link(__MODULE__, parent, name: name)
    def init(parent), do: {:ok, parent}
    def handle_call({:run, fun}, _, parent), do: {:reply, fun.(), parent}

    def handle_info(message, parent) do
      send(parent, {:plugin_hint, self(), message})
      {:noreply, parent}
    end
  end

  defmodule Callback do
    @moduledoc false
    use Application

    def start(_, parent) do
      children =
        for name <- [Publisher, Handler, Other] do
          Supervisor.child_spec({Child, {name, parent}}, id: name)
        end

      Supervisor.start_link(children, strategy: :one_for_one, name: FixtureSupervisor)
    end
  end

  @doc "Bind and start the activation for the calling test; stop and unload it on exit."
  def start do
    Owner.init()
    artifact = %{app: :io_fixture, version: "1.0.0", apps: [%{app: :io_fixture}]}
    owner = Owner.bind(artifact, {make_ref(), 1})

    :ok =
      :application.load(
        {:application, :io_fixture,
         [
           vsn: ~c"1.0.0",
           modules: [Callback, Child],
           applications: [:kernel, :stdlib, :elixir],
           mod: {Callback, self()}
         ]}
      )

    :ok = Application.start(:io_fixture)

    on_exit(fn ->
      Application.stop(:io_fixture)
      Application.unload(:io_fixture)
    end)

    %{owner: owner, artifact: artifact}
  end

  @doc "Register `io_fixture.temperature` and `io_fixture.setpoint` (handled by `Handler`)."
  def register_pair do
    {:ok, "io_fixture.temperature"} =
      plugin(Publisher, fn -> GateIO.register_input(input_definition()) end)

    handler = Process.whereis(Handler)

    {:ok, "io_fixture.setpoint"} =
      plugin(Publisher, fn -> GateIO.register_output(output_definition(), handler) end)
  end

  def input_definition, do: %InputDefinition{id: "temperature", type: :float, unit: "celsius"}

  def output_definition,
    do: %OutputDefinition{
      id: "setpoint",
      type: :float,
      unit: "celsius",
      min: 0.0,
      max: 40.0,
      on_release: :hold,
      evidence: [
        %Evidence{input: "io_fixture.temperature", role: :readback, expect: {:tolerance, 0.5}}
      ]
    }

  def publish(value), do: plugin(Publisher, fn -> GateIO.publish("temperature", value) end)

  @doc "Run `fun` in a fixture process, preserving that process as the actual caller."
  def plugin(name, fun), do: GenServer.call(name, {:run, fun})
end

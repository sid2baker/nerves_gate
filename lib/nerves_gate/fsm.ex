defmodule NervesGate.FSM do
  @moduledoc """
  House defaults for the few lifecycle protocols implemented with Finitomata.

  `on_transition/4` is the reducer. Runtime work is represented by an explicit
  effect in the private payload and launched by `NervesGate.FSM.Listener` only
  after Finitomata accepts the transition.
  """

  defmacro __using__(options) do
    fsm = Keyword.fetch!(options, :fsm)
    timer = Keyword.fetch!(options, :timer)

    supervision =
      if Keyword.get(options, :supervised, true) do
        quote do
          @doc false
          def child_spec(options) do
            %{
              id: Keyword.get(options, :name, __MODULE__),
              start: {__MODULE__, :start_supervised, [options]}
            }
          end

          @doc false
          def start_supervised(options) do
            start_link(
              payload: __MODULE__.new(options),
              name: Keyword.get(options, :name, __MODULE__)
            )
          end
        end
      else
        quote do
        end
      end

    quote do
      use Finitomata,
        fsm: unquote(fsm),
        syntax: :state_diagram,
        telemetria_levels: :none,
        timer: unquote(timer),
        listener: NervesGate.FSM.Listener,
        impl_for: :none

      unquote(supervision)

      @spec graph() :: String.t()
      def graph, do: unquote(fsm)
    end
  end
end

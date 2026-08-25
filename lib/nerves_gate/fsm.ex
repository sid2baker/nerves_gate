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

    quote do
      use Finitomata,
        fsm: unquote(fsm),
        syntax: :state_diagram,
        telemetria_levels: :none,
        timer: unquote(timer),
        listener: NervesGate.FSM.Listener,
        impl_for: :none

      @spec graph() :: String.t()
      def graph, do: unquote(fsm)
    end
  end
end

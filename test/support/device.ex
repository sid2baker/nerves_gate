defmodule NervesGate.TestDevice do
  @moduledoc false

  def start do
    {:ok, supervisor} =
      Supervisor.start_link(
        [
          NervesGate.Network.Host,
          NervesGate.Remote.Host,
          NervesGate.Equipment.Host,
          NervesGate.Indicators.Host,
          NervesGate.Buses.Host
        ],
        strategy: :one_for_one
      )

    Process.unlink(supervisor)
    Application.ensure_all_started(:nerves_gate)
  end
end

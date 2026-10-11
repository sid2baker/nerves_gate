defmodule NervesGate.Connectivity.Plugin do
  @moduledoc "Native Jido input/effect runtime: PropertyTable, Alarmist and bounded read-only probes."
  use Jido.Plugin
  alias NervesGate.Connectivity.{Effect, Probe, Sensor}

  @impl true
  def state_spec(_) do
    {:monitoring,
     Zoi.object(%{
       scope: Zoi.string() |> Zoi.default("gateway"),
       network: Zoi.atom() |> Zoi.default(NervesGate.Network),
       remote: Zoi.atom() |> Zoi.default(NervesGate.Remote),
       probe: Zoi.module() |> Zoi.default(Probe),
       retry_ms: Zoi.integer() |> Zoi.min(1) |> Zoi.default(5_000),
       timeout: Zoi.integer() |> Zoi.min(1) |> Zoi.default(2_000)
     })}
  end

  @impl true
  def directives(_), do: [Effect]

  @impl true
  def child_spec(init), do: Supervisor.child_spec({Sensor, init}, id: __MODULE__)

  @impl true
  def dispatch(runtime, effect, _, _), do: GenServer.call(runtime, {:effect, effect})
end

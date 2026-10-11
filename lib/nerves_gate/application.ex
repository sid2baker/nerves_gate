defmodule NervesGate.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    simulator =
      if NervesGate.target() == :host do
        [
          NervesGate.Network.Host,
          NervesGate.Remote.Host,
          NervesGate.Equipment.Host,
          NervesGate.Indicators.Host
        ]
      else
        []
      end

    children =
      [
        {Phoenix.PubSub, [name: NervesGate.PubSub]},
        {Registry, keys: :unique, name: NervesGate.Registry},
        {PropertyTable, name: NervesGate.Properties},
        {Jido, name: NervesGate.Jido}
      ] ++
        simulator ++
        [
          NervesGate.Network,
          NervesGate.Remote,
          NervesGate.Equipment,
          NervesGate.Indicators,
          NervesGateWeb.Endpoint
        ]

    Supervisor.start_link(children, strategy: :rest_for_one, name: NervesGate.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    NervesGateWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

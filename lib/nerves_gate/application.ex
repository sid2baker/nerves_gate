defmodule NervesGate.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    simulator = if NervesGate.target() == :host, do: [NervesGate.Network.Host], else: []

    children =
      [{Phoenix.PubSub, name: NervesGate.PubSub}] ++
        simulator ++
        [NervesGate.Network, NervesGateWeb.Endpoint]

    Supervisor.start_link(children, strategy: :one_for_one, name: NervesGate.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    NervesGateWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

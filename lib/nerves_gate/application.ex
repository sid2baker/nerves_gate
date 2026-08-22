defmodule NervesGate.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: NervesGate.PubSub},
      NervesGate.Backend,
      NervesGateWeb.Presence,
      NervesGateWeb.Endpoint
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: NervesGate.Supervisor,
      max_restarts: 20,
      max_seconds: 60
    )
  end

  @impl true
  def config_change(changed, removed, _extra) do
    NervesGateWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

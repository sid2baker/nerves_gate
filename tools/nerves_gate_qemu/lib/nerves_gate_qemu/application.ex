defmodule NervesGateQEMU.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: NervesGateQEMU.PubSub},
      NervesGateQEMU.ReleaseServer,
      {Bandit,
       plug: NervesGateQEMU.ReleaseServer,
       scheme: :http,
       port: Application.fetch_env!(:nerves_gate_qemu, :release_port),
       ip: {0, 0, 0, 0}},
      NervesGateQEMUWeb.Endpoint
    ]

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: NervesGateQEMU.Supervisor
    )
  end

  @impl true
  def config_change(changed, removed, _extra) do
    NervesGateQEMUWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end

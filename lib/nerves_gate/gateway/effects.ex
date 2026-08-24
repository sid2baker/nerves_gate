defmodule NervesGate.Gateway.Effects do
  @moduledoc "Local effect boundaries used by the authoritative device-state server."

  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Commissioning.Access
  alias NervesGate.Internet.Manager, as: InternetManager
  alias NervesGate.SSH.Manager, as: SSHManager
  alias NervesGate.Tailnet.Enrollment
  alias NervesGate.Tailnet.Observer

  @spec default() :: map()
  def default do
    %{
      internet: &InternetManager.configure/1,
      internet_restore: &InternetManager.restore/1,
      internet_observe: &NervesGate.Internet.Monitor.poll_now/0,
      stage_tailnet: &Enrollment.stage/3,
      tailnet_restore: &Enrollment.select/1,
      commit_tailnet: &Enrollment.commit/1,
      rollback_tailnet: &Enrollment.rollback/1,
      subnet_router: &configure_subnet_router/2,
      ssh: &SSHManager.set_enabled/1,
      cluster: &ClusterManager.configure/1,
      access: &Access.enable/2,
      disable_access: &Access.disable/0
    }
  end

  defp configure_subnet_router(enabled, routes) do
    advertised = if enabled, do: routes, else: []

    with :ok <-
           Tailscale.await_online(
             timeout: 30_000,
             require: [:authenticated, :tailscale_ipv4]
           ),
         :ok <- Tailscale.set(ssh: false, advertise_routes: advertised),
         {:ok, applied} <- Tailscale.advertised_routes(),
         true <- applied == advertised or enabled do
      Observer.refresh()
      {:ok, if(enabled, do: applied, else: routes)}
    else
      false -> {:error, :route_withdrawal_failed}
      {:error, _reason} = error -> error
      _failure -> {:error, :route_update_failed}
    end
  end
end

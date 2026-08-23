defmodule NervesGate.Gateway.Effects do
  @moduledoc "Local effect boundaries used by the authoritative device-state server."

  alias NervesGate.Cluster.Manager, as: ClusterManager
  alias NervesGate.Commissioning.Access
  alias NervesGate.Internet.Manager, as: InternetManager
  alias NervesGate.Tailnet.Observer
  alias NervesGate.Tailscale

  @spec default() :: map()
  def default do
    %{
      internet: &InternetManager.configure/1,
      internet_restore: &InternetManager.restore/1,
      stage_tailnet: &Tailscale.stage_enrollment/3,
      tailnet_restore: &Tailscale.select_profile/1,
      commit_tailnet: &Tailscale.commit_enrollment/1,
      rollback_tailnet: &Tailscale.rollback_enrollment/1,
      poll_tailnet: &Observer.poll_now/0,
      subnet_router: &Tailscale.configure_subnet_router/2,
      cluster: &ClusterManager.configure/1,
      access: &Access.enable/2,
      disable_access: &Access.disable/0
    }
  end
end

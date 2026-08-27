defmodule NervesGate.Gateway.Runtime do
  @moduledoc "Explicit owner-command boundaries used by the configuration workflow."

  alias NervesGate.Cluster, as: Cluster
  alias NervesGate.Commissioning, as: Commissioning
  alias NervesGate.Internet, as: Internet
  alias NervesGate.SSH, as: SSH
  alias NervesGate.SubnetRouter, as: SubnetRouter
  alias NervesGate.Tailnet.Enrollment

  @spec default() :: map()
  def default do
    %{
      internet: &Internet.configure/1,
      internet_restore: &Internet.restore/1,
      internet_observe: &Internet.poll_now/0,
      stage_tailnet: &Enrollment.stage/3,
      tailnet_restore: &Enrollment.select/1,
      commit_tailnet: &Enrollment.commit/1,
      rollback_tailnet: &Enrollment.rollback/1,
      subnet_router: fn enabled, routes, change_id ->
        SubnetRouter.configure(enabled, routes, SubnetRouter, change_id: change_id)
      end,
      ssh: fn enabled, change_id ->
        SSH.set_enabled(enabled, SSH, change_id: change_id)
      end,
      cluster: &Cluster.configure/1,
      access: &Commissioning.enable/2,
      disable_access: &Commissioning.disable/0,
      firmware_busy: &NervesGate.Firmware.busy?/0
    }
  end
end

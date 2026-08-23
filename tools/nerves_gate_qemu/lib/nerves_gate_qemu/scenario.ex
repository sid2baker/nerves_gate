defmodule NervesGateQEMU.Scenario do
  @moduledoc "Small compositions of host-only QEMU fault primitives."

  alias NervesGateQEMU.Fault

  @spec bad_wan(String.t()) :: {:error, :netem_not_configured}
  def bad_wan(id), do: Fault.loss(id, 30)

  @spec isp_outage(String.t()) :: {:error, :netem_not_configured}
  def isp_outage(id), do: Fault.blackhole(id)

  @spec disconnect(String.t()) :: :ok | {:error, term()}
  def disconnect(id), do: Fault.link_down(id)

  @spec heal_all() :: :ok | {:error, term()}
  defdelegate heal_all, to: Fault
end

defmodule NervesGate.Network.RouteMetric do
  @moduledoc "VintageNet's normal Internet-first policy, including the named cellular interface."

  def compute_metric(name, info) do
    # A connectivity check can finish after hot-unplug. Consult the kernel, not
    # a delayed property, so stale reports cannot install routes on a missing NIC.
    if File.dir?("/sys/class/net/#{name}") do
      interface_metric(name, info)
    else
      :disabled
    end
  end

  defp interface_metric(name, info) do
    type =
      if String.starts_with?(name, "cell"), do: :mobile, else: info.interface_type

    VintageNet.Route.DefaultMetric.compute_metric(name, %{info | interface_type: type})
  end
end

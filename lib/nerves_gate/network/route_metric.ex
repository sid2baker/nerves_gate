defmodule NervesGate.Network.RouteMetric do
  @moduledoc "VintageNet's normal Internet-first policy, including our shared LAN and named modem."

  def compute_metric(name, info) do
    type =
      cond do
        name == "br0" -> :ethernet
        String.starts_with?(name, "cell") -> :mobile
        true -> info.interface_type
      end

    VintageNet.Route.DefaultMetric.compute_metric(name, %{info | interface_type: type})
  end
end

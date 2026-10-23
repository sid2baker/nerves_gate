defmodule Simulator.Scenarios.Firewall do
  @moduledoc false
  alias Simulator.TestQemu, as: Qemu

  def spec,
    do: %{
      :name => "guest IPv4/IPv6 filter, NAT and mangle tables work without Tailscale enrollment"
    }

  def run(%{device: vm}), do: Qemu.check_firewall(vm)
end

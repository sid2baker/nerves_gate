defmodule NervesGate.Scenarios.Firewall do
  @moduledoc false
  alias NervesGate.TestQemu, as: Qemu

  def name, do: "guest IPv4/IPv6 filter, NAT and mangle tables work without Tailscale enrollment"
  def run(vm), do: Qemu.check_firewall(vm)
end

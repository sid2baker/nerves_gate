defmodule Scenarios.Cases.Firewall do
  @moduledoc false
  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      :name => "guest IPv4/IPv6 filter, NAT and mangle tables work without Tailscale enrollment",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}), do: Qemu.check_firewall(vm)
end

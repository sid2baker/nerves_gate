defmodule NervesGate.Network.LAN do
  @moduledoc """
  VintageNet technology for explicitly shared or isolated Ethernet ports.

  Delegates bridge/DHCP/address management to the standard technologies. Keeps
  the fixed Layer 2 bridge alive when changing its management address, including
  after a manager restart. This also avoids VintageNetBridge 0.10.3's delbr-before-
  down teardown bug. Members have no IPv6 autoconfiguration or IPv4 addresses.
  VintageNet remains the sole owner, including interface hotplug and IP cleanup.
  """
  @behaviour VintageNet.Technology

  @impl true
  def normalize(%{vintage_net_bridge: _} = config) do
    config
    |> Map.put(:type, VintageNetBridge)
    |> VintageNetBridge.normalize()
    |> Map.put(:type, __MODULE__)
  end

  def normalize(config) do
    config
    |> Map.put(:type, VintageNetEthernet)
    |> VintageNetEthernet.normalize()
    |> Map.put(:type, __MODULE__)
  end

  @impl true
  def to_raw_config("br0" = ifname, config, opts) do
    raw = VintageNetBridge.to_raw_config(ifname, %{config | type: VintageNetBridge}, opts)
    # The bridge is permanent. Only its address/route/DHCP client is replaced.
    # Do not disrupt equipment-to-equipment traffic on a management IP change.
    [_delete, _create | configure] = raw.up_cmds

    # DHCP down commands only flush the address. Serialize with RouteManager
    # first so an in-flight lease cannot install a route with a removed source IP.
    down = [
      {:fun, VintageNet.RouteManager, :clear_route, [ifname]}
      | Enum.reject(
          raw.down_cmds,
          &(&1 in [
              {:run, "brctl", ["delbr", ifname]},
              {:run, "ip", ["link", "set", ifname, "down"]}
            ])
        )
    ]

    %{
      raw
      | type: __MODULE__,
        source_config: normalize(config),
        up_cmds: [
          {:fun, __MODULE__, :ensure_bridge, []},
          {:fun, __MODULE__, :sync_members, [config.vintage_net_bridge.interfaces]},
          {:fun, __MODULE__, :disable_member_ipv6, [ifname]}
          | configure
        ],
        down_cmds: down
    }
  end

  def to_raw_config(ifname, config, opts) when ifname in ["eth0", "eth1"] do
    raw = VintageNetEthernet.to_raw_config(ifname, %{config | type: VintageNetEthernet}, opts)

    # Also runs when VintageNet configures a newly appeared port.
    commands = [
      {:fun, __MODULE__, :disable_member_ipv6, [ifname]},
      {:run, "ip", ["-4", "addr", "flush", "dev", ifname]}
    ]

    %{
      raw
      | type: __MODULE__,
        source_config: normalize(config),
        up_cmds: commands ++ raw.up_cmds,
        down_cmds: [{:fun, VintageNet.RouteManager, :clear_route, [ifname]} | raw.down_cmds]
    }
  end

  def ensure_bridge do
    if File.dir?("/sys/class/net/br0/bridge") do
      :ok
    else
      VintageNet.Interface.CommandRunner.run({:run, "brctl", ["addbr", "br0"]})
    end
  end

  # The previous bridge watcher has been stopped before these commands run.
  # Detach only ports excluded by the explicit topology; USB is never touched.
  def sync_members(members) do
    Enum.reduce_while(["eth0", "eth1"] -- members, :ok, fn name, :ok ->
      case detach(name) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp detach(name) do
    if File.exists?("/sys/class/net/#{name}/master") do
      VintageNet.Interface.CommandRunner.run({:run, "ip", ["link", "set", name, "nomaster"]})
    else
      :ok
    end
  end

  def disable_member_ipv6(ifname) when ifname in ["eth0", "eth1", "br0"] do
    case File.write("/proc/sys/net/ipv6/conf/#{ifname}/disable_ipv6", "1") do
      # Kernels without IPv6 need no action.
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  @impl true
  def ioctl(_, _, _), do: {:error, :unsupported}
  @impl true
  def check_system(_), do: :ok
end

defmodule NervesGate.Network.LAN do
  @moduledoc """
  VintageNet technology for independent Ethernet ports and the empty metadata bridge.

  No Ethernet port can join the bridge. VintageNet owns interface hotplug, address
  cleanup and the persisted metadata carrier. Ports have no IPv6 autoconfiguration.
  """
  @behaviour VintageNet.Technology

  @impl true
  def normalize(%{vintage_net_bridge: %{interfaces: []}} = config) do
    config
    |> Map.put(:type, VintageNetBridge)
    |> VintageNetBridge.normalize()
    |> Map.put(:type, __MODULE__)
  end

  def normalize(config) when not is_map_key(config, :vintage_net_bridge) do
    config
    |> Map.put(:type, VintageNetEthernet)
    |> VintageNetEthernet.normalize()
    |> Map.put(:type, __MODULE__)
  end

  def normalize(_), do: raise(ArgumentError, "Only independent Ethernet interfaces are supported")

  @impl true
  def to_raw_config("br0" = ifname, %{vintage_net_bridge: %{interfaces: []}} = config, opts) do
    raw = VintageNetBridge.to_raw_config(ifname, %{config | type: VintageNetBridge}, opts)
    # The bridge is permanent. Only its address/route/DHCP client is replaced.
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
          {:fun, __MODULE__, :isolate_ports, []},
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
        up_cmds:
          commands ++
            raw.up_cmds ++
            if(config[:nerves_gate_disabled],
              do: [{:run, "ip", ["link", "set", ifname, "down"]}],
              else: []
            ),
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

  # Only independent ports are supported. USB is never touched.
  def isolate_ports do
    Enum.reduce_while(["eth0", "eth1"], :ok, fn name, :ok ->
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

defmodule NervesGate.Network.LAN do
  @moduledoc "Independent board Ethernet links. No bridges, IPv6 autoconfiguration or persistence."
  @behaviour VintageNet.Technology

  @impl true
  def normalize(config) when not is_map_key(config, :vintage_net_bridge) do
    config
    |> Map.put(:type, VintageNetEthernet)
    |> VintageNetEthernet.normalize()
    |> Map.put(:type, __MODULE__)
  end

  def normalize(_), do: raise(ArgumentError, "Only independent Ethernet interfaces are supported")

  @impl true
  def to_raw_config(ifname, config, opts) do
    raw = VintageNetEthernet.to_raw_config(ifname, %{config | type: VintageNetEthernet}, opts)

    # Runs again when VintageNet configures a newly appeared port. No recovery or
    # management interface uses this technology; Network supplies board Ethernet.
    commands = [
      {:fun, __MODULE__, :disable_ipv6, [ifname]},
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

  def disable_ipv6(ifname) do
    case File.write("/proc/sys/net/ipv6/conf/#{ifname}/disable_ipv6", "1") do
      {:error, :enoent} -> :ok
      result -> result
    end
  end

  @impl true
  def ioctl(_, _, _), do: {:error, :unsupported}
  @impl true
  def check_system(_), do: :ok
end

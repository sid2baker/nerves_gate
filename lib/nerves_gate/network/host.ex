defmodule NervesGate.Network.Host do
  @moduledoc "Explicit host simulator. Never reads or changes the workstation's interfaces."
  use Agent
  @behaviour NervesGate.Network
  alias NervesGate.Config

  def start_link(opts \\ []) do
    Agent.start_link(fn -> %{network: Config.defaults()["network"], overrides: %{}} end,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @impl true
  def apply_config(network, server), do: Agent.update(server, &%{&1 | network: network})

  @impl true
  def snapshot(server) do
    Agent.get(server, fn %{network: network, overrides: overrides} ->
      shared = network["mode"] == "shared"

      ports =
        for name <- ["eth0", "eth1"] do
          address =
            cond do
              shared -> nil
              network["mode"] == "unconfigured" -> Config.address_defaults()
              true -> get_in(Config.ports(network), [name, "address"])
            end

          interface(
            name,
            address,
            if shared do
              "br0"
            end,
            name == "eth0"
          )
        end

      Map.merge(
        %{
          simulated: true,
          bridge:
            interface(
              "br0",
              if shared do
                network["equipment"]
              end,
              nil,
              shared
            ),
          ports: ports,
          usb: interface("usb0", nil, nil, false)
        },
        overrides
      )
    end)
  end

  defp interface(name, address, master, link) do
    addresses =
      case address do
        %{"ip_method" => "static"} ->
          {:ok, prefix} = Config.prefix_length(address["subnet_mask"])
          [%{address: address["static_ip"], prefix_length: prefix}]

        %{"ip_method" => "dhcp"} when link ->
          [%{address: "192.0.2.10", prefix_length: 24}]

        _ ->
          []
      end

    %{
      name: name,
      present: true,
      link: link,
      master: master,
      state: :configured,
      method: if(address, do: address["ip_method"], else: "disabled"),
      addresses: addresses,
      connection: :disconnected
    }
  end

  @doc "Replace simulated observations; use an empty map to restore automatic observations."
  def simulate(overrides, server \\ __MODULE__),
    do: Agent.update(server, &%{&1 | overrides: overrides})
end

defmodule NervesGate.Network.Host do
  @moduledoc "Explicit host simulator. Never reads or changes the workstation's interfaces."
  use Agent
  @behaviour NervesGate.Network.Adapter
  alias NervesGate.{Config, Observations}

  def start_link(opts \\ []) do
    Agent.start_link(
      fn ->
        %{network: Config.defaults()["network"], saved: Config.defaults(), overrides: %{}}
      end,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @impl true
  def load(server), do: {:ok, Agent.get(server, & &1.saved)}

  @impl true
  def save(network, server),
    do: Agent.update(server, &%{&1 | saved: Config.from_network(network)})

  @doc "Reset simulated settings and observations; never touches the workstation."
  def reset(server \\ __MODULE__) do
    update(server, fn _ ->
      %{network: Config.defaults()["network"], saved: Config.defaults(), overrides: %{}}
    end)
  end

  @impl true
  def apply_config(network, server), do: update(server, &%{&1 | network: network})

  @impl true
  def restore(network, server), do: apply_config(network, server)

  @impl true
  def observations(server), do: [{Observations.table(), Observations.host("network", server)}]

  @impl true
  def snapshot(server) do
    Agent.get(server, &observed/1)
  end

  defp observed(%{network: network, overrides: overrides}) do
    shared = network["mode"] == "shared"

    bridge_address =
      if shared do
        network["equipment"]
      end

    master =
      if shared do
        "br0"
      end

    ports =
      Enum.map(["eth0", "eth1"], fn name ->
        interface(name, port_address(network, name), master, name == "eth0")
      end)

    Map.merge(
      %{
        simulated: true,
        bridge: interface("br0", bridge_address, nil, shared),
        ports: ports,
        usb: interface("usb0", nil, nil, false)
      },
      overrides
    )
  end

  defp port_address(%{"mode" => "shared"}, _) do
    nil
  end

  defp port_address(%{"mode" => "unconfigured"}, _) do
    Config.address_defaults()
  end

  defp port_address(network, name) do
    get_in(Config.ports(network), [name, "address"])
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
    do: update(server, &%{&1 | overrides: overrides})

  defp update(server, fun) do
    Agent.update(server, fn state ->
      next = fun.(state)
      Observations.put(Observations.host("network", self()), observed(next))
      next
    end)
  end
end

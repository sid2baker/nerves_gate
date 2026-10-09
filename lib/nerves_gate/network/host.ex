defmodule NervesGate.Network.Host do
  @moduledoc "Explicit host simulator. Never reads or changes the workstation's interfaces."
  use Agent
  @behaviour NervesGate.Network

  def start_link(opts \\ []) do
    Agent.start_link(
      fn -> %{network: NervesGate.Config.defaults()["network"], overrides: %{}} end,
      name: Keyword.get(opts, :name, __MODULE__)
    )
  end

  @impl true
  def apply_config(network, server) do
    Agent.update(server, &%{&1 | network: network})
  end

  @impl true
  def snapshot(server) do
    Agent.get(server, fn %{network: network, overrides: overrides} ->
      {address, prefix} =
        if network["ip_method"] == "static" do
          {:ok, prefix} = NervesGate.Config.prefix_length(network["subnet_mask"])
          {network["static_ip"], prefix}
        else
          {"192.0.2.10", 24}
        end

      Map.merge(
        %{
          simulated: true,
          bridge: %{
            present: true,
            link: true,
            state: :configured,
            method: network["ip_method"],
            addresses: [%{address: address, prefix_length: prefix}]
          },
          ports: [
            %{name: "eth0", present: true, link: true, master: "br0"},
            %{name: "eth1", present: true, link: false, master: "br0"}
          ]
        },
        overrides
      )
    end)
  end

  @doc "Replace simulated observations; use an empty map to restore automatic observations."
  def simulate(overrides, server \\ __MODULE__),
    do: Agent.update(server, &%{&1 | overrides: overrides})
end

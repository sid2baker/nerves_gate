# reach:disable-for-this-file unsafe_atom_creation -- distribution needs node-name atoms
defmodule Mix.Tasks.Dev.Ui do
  @moduledoc """
  Run the gateway UI on the workstation, with code reload, against one device.
  Simulated and real gateways are selected the same way:

      mix dev.ui                               # the only gateway found
      mix dev.ui gateway_a                     # a device of the running mix dev simulator
      mix dev.ui nerves_gate@100.101.102.103   # a real gateway, e.g. an EC100 on the tailnet
      mix dev.ui gateway_a --port 4002

  Without a target, the task looks for the simulator's devices and for gateways
  on the current tailnet, and starts only when it finds exactly one. It reads the
  local Tailscale daemon without changing it and never starts or stops simulated
  devices. Real gateways need development firmware with the same cookie.
  """
  use Mix.Task
  alias NervesGateSim.DevDiscovery

  @shortdoc "Run the gateway UI with code reload against a simulated or real gateway"
  @standard_epmd 4369

  @impl true
  def run(args) do
    {options, targets} = OptionParser.parse!(args, strict: [port: :integer])
    port = options[:port] || 4001
    unless port in 1..65_535, do: Mix.raise("Expected --port in 1..65535")

    target =
      case targets do
        [] -> nil
        [target] -> target
        _ -> Mix.raise("Usage: mix dev.ui [device | nerves_gate@<IPv4>] [--port 4001]")
      end

    Mix.Task.run("compile")
    NervesGateSim.configure()
    simulated = simulated()
    %{node: node, epmd: epmd} = if target, do: resolve(target, simulated), else: find(simulated)

    # erl reads ERL_EPMD_PORT at VM startup. The simulator uses a private EPMD,
    # so a simulated device needs a fresh VM with the session's port.
    if System.get_env("ERL_EPMD_PORT", "#{@standard_epmd}") == "#{epmd}" do
      serve(node, port)
    else
      {:ok, _} = Application.ensure_all_started(:muontrap)

      {_, status} =
        MuonTrap.cmd("mix", ["dev.ui", Atom.to_string(node), "--port", "#{port}"],
          env: [{"ERL_EPMD_PORT", "#{epmd}"}],
          into: IO.stream(),
          stderr_to_stdout: true
        )

      if status != 0, do: Mix.raise("Gateway UI exited (#{status})")
    end
  end

  defp simulated do
    case Mix.Tasks.Qemu.Test.session() do
      {_, state} ->
        for device <- state["lifecycle"]["devices"] do
          %{target: device["id"], node: String.to_atom(device["node"]), epmd: state["epmd_port"]}
        end

      nil ->
        []
    end
  end

  defp real(node), do: %{target: Atom.to_string(node), node: node, epmd: @standard_epmd}

  defp resolve(target, simulated) do
    gateway = Enum.find(simulated, &(target in [&1.target, Atom.to_string(&1.node)]))

    cond do
      gateway ->
        gateway

      DevDiscovery.node_address(target) != :error ->
        real(String.to_atom(target))

      true ->
        Mix.raise("""
        Unknown gateway #{target}. Use a device of the running mix dev simulator
        or the exact firmware node name nerves_gate@<IPv4>.
        """)
    end
  end

  defp find(simulated) do
    case simulated ++ tailnet() do
      [gateway] ->
        gateway

      [] ->
        Mix.raise("""
        No gateway found. Start devices in mix dev, or check that a gateway is online
        with compatible development firmware and that tailnet policy allows EPMD
        (TCP 4369) and Erlang distribution. To probe a known gateway directly:
        mix dev.ui nerves_gate@<IPv4>
        """)

      found ->
        choices = Enum.map_join(found, "\n", &"  mix dev.ui #{&1.target}")
        Mix.raise("Several gateways found. Choose one explicitly:\n#{choices}")
    end
  end

  defp tailnet do
    Mix.shell().info("Looking for gateways on the tailnet...")

    case DevDiscovery.tailnet() do
      {:ok, _local, peers} ->
        start_distribution!()
        for gateway <- DevDiscovery.discover(peers), do: real(gateway.node)

      {:error, message} ->
        Mix.shell().info(message)
        []
    end
  end

  defp serve(node, port) do
    unless Node.alive?(), do: start_distribution!()
    {:ok, address} = DevDiscovery.node_address(Atom.to_string(node))

    unless Enum.any?(DevDiscovery.discover([address]), &(&1.node == node)),
      do: Mix.raise("Gateway #{node} did not reply. Start it and check its development cookie.")

    Application.put_env(:nerves_gate, :backend_node, node)
    endpoint = Application.fetch_env!(:nerves_gate, NervesGateWeb.Endpoint)

    Application.put_env(
      :nerves_gate,
      NervesGateWeb.Endpoint,
      Keyword.merge(endpoint,
        server: true,
        url: [host: "localhost", port: port],
        http: [ip: {127, 0, 0, 1}, port: port]
      )
    )

    # nerves_gate is a runtime: false dependency; start only its UI services.
    {:ok, _} = Application.ensure_all_started(:nerves_gate)
    Mix.shell().info("Gateway UI for #{node}: http://localhost:#{port}")
    unless IEx.started?(), do: Process.sleep(:infinity)
  end

  # Outbound only: without a listener the node is hidden, needs no local EPMD,
  # and never joins a mesh between the simulator's independent guests.
  defp start_distribution! do
    case Node.start(:"nerves_gate_ui_#{System.pid()}@127.0.0.1", dist_listen: false) do
      {:ok, _} -> NervesGate.Distribution.configure_cookie()
      _ -> Mix.raise("Cannot start workstation Erlang distribution.")
    end
  end
end

defmodule Mix.Tasks.Dev.Ec100 do
  @moduledoc """
  Run the workstation UI against an EC100 discovered on the current tailnet.

  If several devices are found, select one explicitly:

      mix dev.ec100 --node nerves_gate@100.x.y.z

  Uses the existing local Tailscale daemon without changing its configuration.
  The device must run compatible development firmware with the same cookie.
  """
  use Mix.Task
  alias NervesGate.DevDiscovery

  @shortdoc "Discover an EC100 on the tailnet and run the workstation UI"

  @impl true
  def run(args) do
    address = options!(args)
    Mix.Task.run("compile")

    {local, peers} =
      case DevDiscovery.tailnet() do
        {:ok, local, peers} -> {local, peers}
        {:error, message} -> Mix.raise(message)
      end

    start_distribution!(local)
    Mix.shell().info("Looking for EC100 gateways on the tailnet...")

    gateways = DevDiscovery.discover(if address, do: [address], else: peers)
    backend = select!(gateways)
    Mix.shell().info("Connecting to #{backend}")
    System.put_env("NERVES_GATE_BACKEND_NODE", Atom.to_string(backend))
    Mix.Task.run("phx.server")
  end

  defp options!(args) do
    {options, rest} = OptionParser.parse!(args, strict: [node: :string])
    if rest != [], do: Mix.raise("Usage: mix dev.ec100 [--node nerves_gate@<IPv4>]")

    if value = options[:node] do
      case DevDiscovery.node_address(value) do
        {:ok, address} -> address
        :error -> Mix.raise("Use the exact firmware node name: --node nerves_gate@<IPv4>")
      end
    end
  end

  defp start_distribution!(address) do
    # A unique UI name also permits a second launcher without taking over an
    # existing distribution node. EPMD is OTP's registry, not a VPN service.
    epmd =
      Path.join([
        to_string(:code.root_dir()),
        "erts-#{:erlang.system_info(:version)}",
        "bin/epmd"
      ])

    name = :"nerves_gate_ui_#{System.pid()}@#{:inet.ntoa(address)}"

    with {_, 0} <- System.cmd(epmd, ["-daemon"], stderr_to_stdout: true),
         {:ok, _} <- Node.start(name, name_domain: :longnames) do
      NervesGate.Distribution.configure_cookie()
    else
      _ -> Mix.raise("Cannot start workstation Erlang distribution.")
    end
  end

  defp select!(gateways) do
    case DevDiscovery.select(gateways, :ec100) do
      {:ok, node} ->
        node

      {:error, :not_found} ->
        Mix.raise("""
        No reachable EC100 gateway found. Check that the device is online with
        compatible development firmware and the same distribution cookie, and
        that tailnet policy allows EPMD (TCP 4369) and Erlang distribution traffic.
        To probe a known device directly: mix dev.ec100 --node nerves_gate@<IPv4>
        """)

      {:error, {:multiple, nodes}} ->
        choices = Enum.map_join(nodes, "\n", &"  mix dev.ec100 --node #{&1}")
        Mix.raise("Several EC100 gateways found. Choose one explicitly:\n#{choices}")
    end
  end
end

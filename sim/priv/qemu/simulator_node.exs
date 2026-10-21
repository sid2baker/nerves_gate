alias NervesGateSim.Simulator

# mix run --no-start keeps Mix's Logger, so apply the configured level (test: warning).
if level = Application.get_env(:logger, :level), do: Logger.configure(level: level)

{:ok, _} = Application.ensure_all_started(:muontrap)
{:ok, _} = Application.ensure_all_started(:ssh)
Application.put_env(:kernel, :inet_dist_use_interface, {127, 0, 0, 1})
# Hidden native distribution prevents guest-to-guest mesh discovery: loopback
# forwards belong to the host, not to the guests' independent IP stacks.
{:ok, _} = Node.start(:"simulator@127.0.0.1", name_domain: :longnames, hidden: true)
Node.set_cookie(:mycookie)
:ok = :net_kernel.monitor_nodes(true, node_type: :all)

config = Simulator.config(System.fetch_env!("QEMU_SIM_CONFIG"), System.fetch_env!("QEMU_SIM_DIR"))
{:ok, simulator} = Simulator.start_link(config)
# The simulator remains empty until Start is explicitly admitted by the UI.

unless :"gateway_ui@127.0.0.1" in Node.list(:connected) do
  receive do
    {:nodeup, :"gateway_ui@127.0.0.1", _} -> :ok
    {:nodedown, :"gateway_ui@127.0.0.1", _} -> raise "UI disconnected during startup"
  after
    30_000 -> raise "UI did not connect to the simulator"
  end
end

receive do
  {:nodedown, :"gateway_ui@127.0.0.1", _} -> GenServer.stop(simulator, :normal, 30_000)
end

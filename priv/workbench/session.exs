# The single Workbench session BEAM, started by Workbench.Launcher under flock and
# MuonTrap. It owns the simulator, gateway directory, runner, jobs and UI.
Workbench.configure()
:erlang.system_flag(:backtrace_depth, 32)
alias Scenarios.Runner
alias Workbench.Session
Process.register(self(), :nerves_gate_workbench_session)

# mix run --no-start keeps Mix's Logger, so apply the configured level (test: warning).
if level = Application.get_env(:logger, :level), do: Logger.configure(level: level)

dir = System.fetch_env!("WORKBENCH_DIR")
ci? = System.get_env("WORKBENCH_CI") == "true"
port = String.to_integer(System.fetch_env!("WORKBENCH_HTTP_PORT"))

{:ok, _} = Application.ensure_all_started(:muontrap)
node = Workbench.Distribution.start!(dir)
{:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one, max_restarts: 0)

simulator_dir =
  Path.expand("_build/simulator/#{System.system_time(:millisecond)}-#{System.pid()}")

File.mkdir_p!(simulator_dir)
File.chmod!(simulator_dir, 0o700)
IO.puts("Simulator diagnostics: #{simulator_dir}")
config = Simulator.config(System.fetch_env!("QEMU_SIM_CONFIG"), simulator_dir)
{:ok, _} = Supervisor.start_child(supervisor, {Simulator, config})

site = Application.fetch_env!(:nerves_gate_workbench, WorkbenchWeb.Endpoint)

Application.put_env(
  :nerves_gate_workbench,
  WorkbenchWeb.Endpoint,
  Keyword.merge(site,
    server: true,
    url: [host: "localhost", port: port],
    http: [ip: {127, 0, 0, 1}, port: port]
  )
)

views = fn timeout, message ->
  Stream.repeatedly(fn ->
    receive do
      {:scenarios, view} -> view
    after
      timeout -> raise message
    end
  end)
end

result =
  try do
    {:ok, _} = Application.ensure_all_started(:nerves_gate_workbench)

    if (path = System.get_env("NERVES_GATE_APP", "")) != "",
      do: {:ok, _} = Workbench.Applications.open(path)

    {:ok, _} = Supervisor.start_child(supervisor, Workbench.SessionServices)
    {:ok, {_, listening_port}} = WorkbenchWeb.Endpoint.server_info(:http)
    System.put_env("WORKBENCH_HTTP_PORT", Integer.to_string(listening_port))
    Session.advertise!(dir, listening_port, node)

    if ci? do
      Runner.subscribe()
      :ok = Runner.lifecycle("start")

      views.(900_000, "QEMU startup stopped reporting")
      |> Enum.find(fn view ->
        if view.lifecycle.status in [:failed, :unavailable],
          do: raise("QEMU startup failed: #{view.lifecycle.phase}")

        view.lifecycle.status == :ready
      end)

      # CI runs on the first device; multi-device scenarios hold the others.
      [first | _] = Runner.snapshot().lifecycle.devices
      {:ok, id} = Runner.run(first.id, System.fetch_env!("WORKBENCH_SCENARIO"))

      views.(600_000, "QEMU runner stopped reporting")
      |> Enum.reduce_while(MapSet.new(), fn view, printed ->
        run = Enum.find(view.runs, &(&1.id == id))
        printed = Workbench.CLI.print_rows(run, printed)
        if run.status == :running, do: {:cont, printed}, else: {:halt, run.status}
      end)
    else
      IO.puts(
        "Workbench ready: http://localhost:#{port} · node #{node} (hidden, cookie mycookie)"
      )

      Session.await_stop()
    end
  after
    if Process.whereis(NervesGate.PubSub), do: Runner.unsubscribe()
    Supervisor.stop(supervisor, :normal, 30_000)
  end

if result not in [:passed, :stopped], do: Mix.raise("QEMU scenarios failed")

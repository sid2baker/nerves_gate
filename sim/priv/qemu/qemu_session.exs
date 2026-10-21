# The UI owns only the simulator BEAM's MuonTrap wrapper. QMP sockets, disks and
# Ethernet relays stay inside that BEAM, never in scenario/UI worker processes.
NervesGateSim.configure()
alias NervesGateSim.{DevSession, QemuTests, Simulator}
Process.register(self(), DevSession)

# mix run --no-start keeps Mix's Logger, so apply the configured level (test: warning).
if level = Application.get_env(:logger, :level), do: Logger.configure(level: level)

{:ok, _} = Application.ensure_all_started(:muontrap)
{:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one, max_restarts: 0)

epmd =
  Path.join([to_string(:code.root_dir()), "erts-#{:erlang.system_info(:version)}", "bin/epmd"])

{:ok, epmd_daemon} =
  Supervisor.start_child(
    supervisor,
    Supervisor.child_spec(
      {MuonTrap.Daemon,
       [
         epmd,
         ["-address", "127.0.0.1", "-port", System.fetch_env!("ERL_EPMD_PORT")],
         []
       ]},
      id: :epmd
    )
  )

# Do not let Node.start race the supervised EPMD and auto-start an unowned one.
# A names request uses ERL_EPMD_PORT; a bare connection makes EPMD log a partial packet.
true =
  Enum.reduce_while(1..100, false, fn _, _ ->
    unless Process.alive?(epmd_daemon), do: raise("Session EPMD exited during startup")

    case :erl_epmd.names({127, 0, 0, 1}) do
      {:ok, _names} ->
        {:halt, true}

      {:error, _} ->
        Process.sleep(50)
        {:cont, false}
    end
  end)

# The UI initiates connections and needs no inbound distribution listener.
{:ok, _} = Node.start(:"gateway_ui@127.0.0.1", name_domain: :longnames, dist_listen: false)
Node.set_cookie(:mycookie)
dir = Path.expand("_build/qemu-tests/#{System.system_time(:millisecond)}-#{System.pid()}")
File.mkdir_p!(dir)
File.chmod!(dir, 0o700)
IO.puts("Simulator diagnostics: #{dir}")

{:ok, simulator} =
  Supervisor.start_child(
    supervisor,
    Supervisor.child_spec(
      {MuonTrap.Daemon,
       [
         "mix",
         ["do", "compile", "+", "run", "--no-start", NervesGateSim.script("simulator_node")],
         [env: [{"QEMU_SIM_DIR", dir}], stderr_to_stdout: true, logger_fun: &IO.puts/1]
       ]},
      id: :simulator,
      restart: :temporary
    )
  )

connected =
  Enum.reduce_while(1..120, false, fn _, _ ->
    unless Process.alive?(simulator), do: raise("Simulator exited during startup")

    ready =
      Node.connect(:"simulator@127.0.0.1") and
        is_pid(:erpc.call(:"simulator@127.0.0.1", Process, :whereis, [Simulator], 5000))

    if ready do
      {:halt, true}
    else
      Process.sleep(500)
      {:cont, false}
    end
  end)

true = connected

Application.put_env(:nerves_gate, :simulator_node, :"simulator@127.0.0.1")

# The session serves the simulator site, not the gateway UI. The gateway
# Endpoint runs without a listener so scenarios can check its configuration.
Application.put_env(:nerves_gate, :services, [
  NervesGateSim.QemuTests,
  NervesGateWeb.Endpoint,
  NervesGateSimWeb.Endpoint
])

gateway = Application.fetch_env!(:nerves_gate, NervesGateWeb.Endpoint)
Application.put_env(:nerves_gate, NervesGateWeb.Endpoint, Keyword.put(gateway, :server, false))
port = String.to_integer(System.fetch_env!("QEMU_HTTP_PORT"))
site = Application.fetch_env!(:nerves_gate, NervesGateSimWeb.Endpoint)

site =
  Keyword.merge(site,
    server: true,
    url: [host: "localhost", port: port],
    http: [ip: {:local, System.fetch_env!("QEMU_HTTP_SOCKET")}, port: 0]
  )

Application.put_env(:nerves_gate, NervesGateSimWeb.Endpoint, site)

views = fn timeout, message ->
  Stream.repeatedly(fn ->
    receive do
      {:qemu_tests, view} -> view
    after
      timeout -> raise message
    end
  end)
end

result =
  try do
    # The simulator's own dependencies (such as Req), then the workstation UI.
    {:ok, _} = Application.ensure_all_started(:nerves_gate_sim)
    {:ok, _} = Application.ensure_all_started(:nerves_gate)

    if System.get_env("QEMU_CI") != "true" do
      [spec] =
        Bandit.PhoenixAdapter.child_specs(NervesGateSimWeb.Endpoint,
          otp_app: :nerves_gate,
          code_reloader: site[:code_reloader],
          http: [ip: {127, 0, 0, 1}, port: port]
        )

      {:ok, _} = Supervisor.start_child(supervisor, spec)
    end

    if System.get_env("QEMU_CI") == "true" do
      QemuTests.subscribe()
      :ok = QemuTests.lifecycle("start")

      views.(900_000, "QEMU startup stopped reporting")
      |> Enum.find(fn view ->
        if view.lifecycle.status in [:failed, :unavailable],
          do: raise("QEMU startup failed: #{view.lifecycle.phase}")

        view.lifecycle.status == :ready
      end)

      # CI runs on the first device; multi-device scenarios hold the others.
      [first | _] = QemuTests.snapshot().lifecycle.devices
      {:ok, id} = QemuTests.run(first.id, System.fetch_env!("QEMU_SCENARIO"))

      views.(600_000, "QEMU runner stopped reporting")
      |> Enum.reduce_while(MapSet.new(), fn view, printed ->
        run = Enum.find(view.runs, &(&1.id == id))

        printed =
          Enum.reduce(run.rows, printed, fn row, printed ->
            if row.status in [:passed, :failed] and not MapSet.member?(printed, row.id) do
              IO.puts("#{row.status}: #{row.id} (#{row.milliseconds} ms) #{row.detail}")
              MapSet.put(printed, row.id)
            else
              printed
            end
          end)

        if run.status == :running, do: {:cont, printed}, else: {:halt, run.status}
      end)
    else
      DevSession.await_stop(System.fetch_env!("QEMU_SESSION_DIR"))
    end
  after
    if Process.whereis(NervesGate.PubSub), do: QemuTests.unsubscribe()
    Application.stop(:nerves_gate)
    Supervisor.stop(supervisor, :normal, 30_000)
  end

if result not in [:passed, :stopped], do: Mix.raise("QEMU scenarios failed")

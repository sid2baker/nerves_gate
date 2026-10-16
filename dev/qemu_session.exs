# The UI owns only the simulator BEAM's MuonTrap wrapper. QMP sockets, disks and
# Ethernet relays stay inside that BEAM, never in scenario/UI worker processes.
alias NervesGate.{QemuTests, Simulator}

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
epmd_port = System.fetch_env!("ERL_EPMD_PORT") |> String.to_integer()

true =
  Enum.reduce_while(1..100, false, fn _, _ ->
    unless Process.alive?(epmd_daemon), do: raise("Session EPMD exited during startup")

    case :gen_tcp.connect({127, 0, 0, 1}, epmd_port, [active: false], 100) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
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
         ["do", "compile", "+", "run", "--no-start", "dev/simulator_node.exs"],
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
Application.delete_env(:nerves_gate, :backend_node)
endpoint = Application.fetch_env!(:nerves_gate, NervesGateWeb.Endpoint)

endpoint =
  Keyword.merge(endpoint,
    server: true,
    url: [host: "localhost", port: String.to_integer(System.fetch_env!("QEMU_HTTP_PORT"))],
    http: [ip: {:local, System.fetch_env!("QEMU_HTTP_SOCKET")}, port: 0]
  )

Application.put_env(:nerves_gate, NervesGateWeb.Endpoint, endpoint)

result =
  try do
    {:ok, _} = Application.ensure_all_started(:nerves_gate)

    if System.get_env("QEMU_CI") != "true" do
      [spec] =
        Bandit.PhoenixAdapter.child_specs(NervesGateWeb.Endpoint,
          otp_app: :nerves_gate,
          code_reloader: endpoint[:code_reloader],
          http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.fetch_env!("QEMU_HTTP_PORT"))]
        )

      {:ok, _} = Supervisor.start_child(supervisor, spec)
    end

    if System.get_env("QEMU_CI") == "true" do
      QemuTests.subscribe()
      :ok = QemuTests.lifecycle("start")

      Stream.repeatedly(fn ->
        receive do
          {:qemu_tests, view} -> view
        after
          900_000 -> raise "QEMU startup stopped reporting"
        end
      end)
      |> Enum.reduce_while(:starting, fn view, _ ->
        case view.lifecycle.status do
          :ready ->
            {:halt, :ready}

          status when status in [:failed, :unavailable] ->
            raise "QEMU startup failed: #{view.lifecycle.phase}"

          _ ->
            {:cont, :starting}
        end
      end)

      {:ok, _} = QemuTests.run(System.fetch_env!("QEMU_SCENARIO"))

      Stream.repeatedly(fn ->
        receive do
          {:qemu_tests, view} -> view
        after
          600_000 -> raise "QEMU runner stopped reporting"
        end
      end)
      |> Enum.reduce_while(MapSet.new(), fn view, seen ->
        seen =
          Enum.reduce(view.rows, seen, fn row, seen ->
            if row.status in [:passed, :failed] and not MapSet.member?(seen, row.id) do
              IO.puts("#{row.status}: #{row.id} (#{row.milliseconds} ms) #{row.detail}")
              MapSet.put(seen, row.id)
            else
              seen
            end
          end)

        if view.status == :running, do: {:cont, seen}, else: {:halt, view.status}
      end)
    else
      Process.sleep(:infinity)
    end
  after
    QemuTests.unsubscribe()
    Application.stop(:nerves_gate)
    Supervisor.stop(supervisor, :normal, 30_000)
  end

if result != :passed, do: Mix.raise("QEMU scenarios failed")

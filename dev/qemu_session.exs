# Both development and CI enter here, inside an empty user/network namespace.
alias NervesGate.{QemuTests, TestQemu}
{:ok, _} = Application.ensure_all_started(:muontrap)
vm = TestQemu.start()
Application.put_env(:nerves_gate, :qemu_vm, vm)
endpoint = Application.fetch_env!(:nerves_gate, NervesGateWeb.Endpoint)

endpoint =
  Keyword.merge(endpoint,
    server: true,
    http: [ip: {:local, System.fetch_env!("QEMU_HTTP_SOCKET")}, port: 0]
  )

Application.put_env(:nerves_gate, NervesGateWeb.Endpoint, endpoint)

result =
  try do
    {:ok, _} = Application.ensure_all_started(:nerves_gate)
    :ok = :gen_tcp.controlling_process(vm.socket, Process.whereis(QemuTests))

    if System.get_env("QEMU_CI") == "true" do
      QemuTests.subscribe()
      {:ok, _} = QemuTests.run(System.fetch_env!("QEMU_SCENARIO"))

      Stream.repeatedly(fn ->
        receive do
          {:qemu_tests, view} -> view
        after
          310_000 -> raise "QEMU runner stopped reporting"
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
    Application.stop(:nerves_gate)
    Supervisor.stop(NervesGate.TestQemu.Supervisor, :normal)
    TestQemu.cleanup()
  end

if result != :passed, do: Mix.raise("QEMU scenarios failed")

# Pasta creates the user/network namespace; unshare creates the private mounts.
alias NervesGate.{QemuTests, TestQemu}

for {namespace, variable} <- [net: "NERVES_GATE_HOST_NETNS", mnt: "NERVES_GATE_HOST_MNTNS"] do
  if File.read_link!("/proc/self/ns/#{namespace}") == System.fetch_env!(variable),
    do: raise("Refusing to configure QEMU in the workstation #{namespace} namespace")
end

# QEMU's DNS proxy reads resolv.conf, so give it pasta's DNS-only forwarding
# address. This also works when the workstation resolver listens on loopback.
resolver = Path.join(Path.dirname(System.fetch_env!("QEMU_HTTP_SOCKET")), "resolv.conf")
File.write!(resolver, "nameserver 192.0.2.3\n")
{_, 0} = System.cmd("mount", ["--bind", resolver, "/etc/resolv.conf"], stderr_to_stdout: true)

{:ok, _} = Application.ensure_all_started(:muontrap)
vm = TestQemu.start()
Application.put_env(:nerves_gate, :qemu_vm, vm)
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
    # PubSub links subscribers to its Registry partition. Unsubscribe before
    # stopping the application so its shutdown cannot kill this cleanup owner.
    QemuTests.unsubscribe()
    Application.stop(:nerves_gate)
    Supervisor.stop(NervesGate.TestQemu.Supervisor, :normal)
    TestQemu.cleanup()
  end

if result != :passed, do: Mix.raise("QEMU scenarios failed")

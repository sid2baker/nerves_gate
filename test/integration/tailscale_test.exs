# Isolated LocalAPI compatibility check. Never logs in or attaches to a host daemon.
# MIX_TARGET=host mix run --no-start test/integration/tailscale_test.exs /absolute/path/to/tailscaled
unless Mix.target() == :host, do: raise("Run this check with MIX_TARGET=host")
if Process.whereis(Tailscale.Supervisor), do: raise("A Tailscale application is already running")
[binary] = System.argv()

unless Path.type(binary) == :absolute and File.regular?(binary),
  do: raise("Supply a daemon binary")

ExUnit.start(autorun: false)

defmodule NervesGate.TailscaleIntegration do
  use ExUnit.Case, async: false
  alias NervesGate.Remote
  @moduletag timeout: 30_000

  setup_all do
    [binary] = System.argv()

    directory =
      Path.join(System.tmp_dir!(), "nerves-gate-ts-#{System.unique_integer([:positive])}")

    for {key, value} <- [
          daemon_path: binary,
          data_dir: directory,
          state_dir: Path.join(directory, "identity"),
          socket: Path.join(directory, "run/tailscaled.sock"),
          tun: :userspace,
          manage_daemon: true,
          retry_min: 100,
          retry_max: 500
        ],
        do: Application.put_env(:tailscale, key, value)

    on_exit(fn ->
      Application.stop(:tailscale)
      File.rm_rf!(directory)
    end)

    {:ok, _} = Application.ensure_all_started(:tailscale)
    {:ok, _} = Application.ensure_all_started(:jido)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    start_supervised!({Phoenix.PubSub, name: NervesGate.PubSub})
    start_supervised!({Registry, keys: :unique, name: NervesGate.Registry})
    start_supervised!({PropertyTable, name: NervesGate.Properties})
    start_supervised!({Jido, name: NervesGate.Jido})
    start_supervised!({Remote, adapter: {Remote.Tailscale, nil}, poll_ms: 10})
    :ok = Tailscale.Monitor.ready(Tailscale.Monitor, 10_000)
    eventually(fn -> Tailscale.get_configuration() != nil end)
    :ok
  end

  test "real daemon status, async rename, DNS preference and existing routes are preserved" do
    projection = NervesGate.status()
    assert projection.remote_access.available
    assert projection.remote_access.state == "offline"
    refute projection.remote_access.verified
    assert projection.remote_access.permitted_routes == nil
    assert projection.remote_access.version != nil
    assert Remote.login_url() == nil

    :ok =
      Tailscale.update_configuration(%{
        accept_routes: true,
        advertise_routes: ["192.168.80.0/24"]
      })

    assert :ok = NervesGate.remote_configure("gateway-compatibility-check")

    eventually(fn -> NervesGate.status().remote_access.operation == nil end)
    remote = NervesGate.status().remote_access
    assert remote.error == nil
    assert remote.hostname == "gateway-compatibility-check"
    assert remote.advertised_routes == ["192.168.80.0/24"]
    assert remote.state == "offline"
    refute Tailscale.get_configuration().accept_dns
    assert Tailscale.get_configuration().accept_routes

    # A controller restart reads the live daemon; gateway defaults must not replace it.
    Supervisor.terminate_child(Tailscale.Supervisor, Tailscale.Controller)
    {:ok, _} = Supervisor.restart_child(Tailscale.Supervisor, Tailscale.Controller)
    eventually(fn -> Tailscale.get(["configuration", "state"]) == :ready end)
    assert Tailscale.get_configuration().hostname == "gateway-compatibility-check"

    IO.puts(
      "Verified isolated tailscaled #{remote.version}; no account enrollment or kernel routing"
    )
  end

  defp eventually(fun, attempts \\ 200)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end
end

result = ExUnit.run()
if result.failures > 0, do: System.halt(1)

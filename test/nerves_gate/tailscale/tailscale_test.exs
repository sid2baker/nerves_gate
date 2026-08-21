defmodule NervesGate.TailscaleTest do
  use ExUnit.Case

  alias NervesGate.Network.Config
  alias NervesGate.Store
  alias NervesGate.Tailscale.Manager
  alias NervesGate.TestScenario
  alias NervesGate.TestTailscaleClient

  setup do
    {:ok, _pid} = TestTailscaleClient.reset({:ok, %{login: {:error, :invalid_key}}})
    old_backend = Application.get_env(:nerves_gate, :tailscale_backend)
    old_manager = Application.get_env(:nerves_gate, :tailscale_manager)
    Application.put_env(:nerves_gate, :tailscale_backend, TestTailscaleClient)
    Application.put_env(:nerves_gate, :tailscale_manager, NervesGate.TestTailscaleManager)

    on_exit(fn ->
      restore_env(:tailscale_backend, old_backend)
      restore_env(:tailscale_manager, old_manager)
      stop_if_running(TestTailscaleClient)
    end)

    :ok
  end

  test "invalid Tailscale auth key is discarded while network configuration remains" do
    root = TestScenario.temporary_root(:invalid_auth)
    :ok = Store.initialize(root)
    network = TestScenario.dhcp()
    :ok = Store.write_network(network, root)

    assert {:error, :authentication_failed} = NervesGate.Tailscale.enroll("tskey-invalid")
    assert {:ok, %Config{method: :dhcp}} = Store.read_network(root)
    refute inspect(NervesGate.Tailscale) =~ "tskey-invalid"
  end

  test "missing or corrupt pinned binaries are rejected" do
    root = TestScenario.temporary_root(:binary)
    cli = Path.join(root, "tailscale")
    daemon = Path.join(root, "tailscaled")

    assert {:error, :missing_pinned_binary} =
             Manager.validate_binary_paths(%{cli_path: cli, daemon_path: daemon})

    File.mkdir_p!(root)
    File.write!(cli, "corrupt")
    File.write!(daemon, "corrupt")
    File.chmod!(cli, 0o755)
    File.chmod!(daemon, 0o755)

    assert {:error, :missing_pinned_binary} =
             Manager.validate_binary_paths(%{cli_path: cli, daemon_path: daemon})
  end

  test "tailscaled crash is isolated and scheduled for supervised recovery" do
    executable = System.find_executable("true")
    name = String.to_atom("tailscale_manager_#{System.unique_integer([:positive])}")

    {:ok, manager} =
      Manager.start_link(
        name: name,
        enabled: true,
        retry: 10,
        binary_paths: %{cli_path: executable, daemon_path: executable}
      )

    assert :ok = Manager.ensure_started(manager)
    Process.exit(Process.whereis(NervesGate.Tailscale.Daemon), :kill)
    assert_eventually(fn -> :sys.get_state(manager).retry > 10 end)
    assert Process.alive?(manager)
  end

  test "kernel TUN mode is mandatory in runtime configuration" do
    source = File.read!("lib/nerves_gate/tailscale/manager.ex")
    assert source =~ "tun: :kernel"
    refute source =~ "tun: :userspace"
  end

  defp stop_if_running(name) do
    if pid = Process.whereis(name), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp assert_eventually(predicate, attempts \\ 50) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not become true")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:nerves_gate, key)
  defp restore_env(key, value), do: Application.put_env(:nerves_gate, key, value)
end

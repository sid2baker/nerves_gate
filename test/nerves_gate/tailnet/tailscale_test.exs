defmodule NervesGate.Tailnet.TailscaleTest do
  use ExUnit.Case

  alias NervesGate.Internet.Config
  alias NervesGate.Store
  alias NervesGate.Tailnet.Manager
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

  test "staged enrollment can switch back to the previous account profile" do
    TestTailscaleClient.put(
      {:ok,
       %{
         "Self" => %{"Online" => true},
         profiles: [
           %{"id" => "old-profile", "nickname" => "known-good", "selected" => true}
         ]
       }}
    )

    assert {:ok, "old-profile"} = NervesGate.Tailscale.current_profile_id()

    assert {:ok, metadata} =
             NervesGate.Tailscale.stage_enrollment(
               "tskey-auth-candidate",
               "change-123",
               "old-profile"
             )

    assert metadata["candidate_profile_id"] == "candidate-profile"
    assert {:ok, "candidate-profile"} = NervesGate.Tailscale.current_profile_id()
    assert :ok = NervesGate.Tailscale.rollback_enrollment(metadata)
    assert {:ok, "old-profile"} = NervesGate.Tailscale.current_profile_id()
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

    send(manager, {:internet_changed, %{online: true}})
    assert :ok = Manager.ensure_started(manager)
    Process.exit(Process.whereis(NervesGate.Tailscale.Daemon), :kill)
    assert_eventually(fn -> :sys.get_state(manager).retry > 10 end)
    assert Process.alive?(manager)
  end

  test "runtime repair is blocked while Internet is unavailable" do
    name = String.to_atom("tailnet_repair_#{System.unique_integer([:positive])}")
    {:ok, manager} = Manager.start_link(name: name, enabled: false)
    on_exit(fn -> if Process.alive?(manager), do: GenServer.stop(manager) end)

    assert :blocked = Manager.repair_runtime(manager)
  end

  test "kernel TUN mode is mandatory in runtime configuration" do
    source = File.read!("lib/nerves_gate/tailnet/manager.ex")
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

defmodule NervesGate.SetupTest do
  use ExUnit.Case

  alias NervesGate.Internet.Config
  alias NervesGate.Setup
  alias NervesGate.Store
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:setup_flow)
    :ok = Store.initialize(root)
    owner = self()

    ops = %{
      internet: fn config ->
        send(owner, {:internet, config})
        {:ok, TestScenario.checks()}
      end,
      enroll_tailnet: fn token ->
        send(owner, {:tailnet, token})
        :ok
      end,
      start_tailnet: fn -> :ok end,
      poll_tailnet: fn -> :ok end,
      configure_cluster: fn group ->
        send(owner, {:cluster_configuration, group})
        Store.write_cluster(group, root)
      end,
      access: fn mode, uplink ->
        send(owner, {:access, mode, uplink})
        {:ok, []}
      end,
      disable_access: fn ->
        send(owner, :disable_access)
        :ok
      end
    }

    name = String.to_atom("setup_#{System.unique_integer([:positive])}")
    {:ok, setup} = Setup.start_link(name: name, root: root, ops: ops)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root, setup: setup, ops: ops}
  end

  test "the complete setup is three explicit, independently testable calls", %{
    root: root,
    setup: setup
  } do
    assert_receive {:access, :commissioning, nil}

    assert {:ok, :tailscale} = Setup.configure_internet(%{"ip_address" => "dhcp"}, setup)
    assert_receive {:internet, %Config{interface: "eth0", method: :dhcp}}
    assert {:ok, %{"phase" => "tailscale"}} = Store.read_setup(root)

    token = "tskey-auth-not-a-real-token"
    assert {:ok, :cluster} = Setup.configure_tailscale(token, setup)
    assert_receive {:tailnet, ^token}
    assert {:ok, %{"phase" => "cluster"}} = Store.read_setup(root)

    assert {:ok, :ready} = Setup.configure_cluster(setup)
    assert_receive {:cluster_configuration, nil}
    assert_receive :disable_access, 1_500
    assert {:ok, %{"phase" => "ready"}} = Store.read_setup(root)
    assert {:ok, nil} = Store.read_cluster(root)
    refute File.read!(Path.join(root, "setup.json")) =~ token
  end

  test "the backend API persists an explicit public cluster group", %{root: root, setup: setup} do
    group = "Plant_floor"

    assert {:ok, :tailscale} = Setup.configure_internet(%{"ip_address" => "dhcp"}, setup)
    assert {:ok, :cluster} = Setup.configure_tailscale("tskey-not-real", setup)
    assert {:ok, :ready} = Setup.configure_cluster_group(group, setup)
    assert_receive {:cluster_configuration, ^group}
    assert {:ok, ^group} = Store.read_cluster(root)
  end

  test "completed commissioning is immutable through setup operations", %{setup: setup} do
    assert {:ok, :tailscale} = Setup.configure_internet(%{"ip_address" => "dhcp"}, setup)
    assert {:ok, :cluster} = Setup.configure_tailscale("tskey-not-real", setup)
    assert {:ok, :ready} = Setup.configure_cluster(setup)

    assert {:error, :guarded_settings_required} =
             Setup.configure_internet(%{"ip_address" => "dhcp"}, setup)

    assert {:error, :guarded_settings_required} =
             Setup.configure_tailscale("tskey-replacement", setup)

    assert {:error, :guarded_settings_required} =
             Setup.configure_cluster_group("Replacement_group", setup)

    assert Setup.status(setup).phase == :ready
  end

  test "a static IP uses the clear API field names", %{setup: setup} do
    params = %{
      "ip_address" => "192.0.2.20",
      "prefix_length" => "24",
      "gateway" => "192.0.2.1",
      "dns" => "1.1.1.1"
    }

    assert {:ok, :tailscale} = Setup.configure_internet(params, setup)

    assert_receive {:internet,
                    %Config{
                      method: :static,
                      address: "192.0.2.20",
                      gateway: "192.0.2.1",
                      dns_primary: "1.1.1.1"
                    }}
  end

  test "invalid Internet settings fail before touching the network", %{setup: setup} do
    assert {:error, errors} = Setup.configure_internet(%{"ip_address" => "invalid"}, setup)
    assert errors.address
    refute_receive {:internet, _config}
  end

  test "development mode keeps setup access after commissioning", %{ops: ops} do
    root = TestScenario.temporary_root(:local_dashboard)
    on_exit(fn -> File.rm_rf!(root) end)
    :ok = Store.initialize(root)

    owner = self()

    ops =
      Map.put(ops, :configure_cluster, fn group ->
        send(owner, {:cluster_configuration, group})
        Store.write_cluster(group, root)
      end)

    {:ok, setup} =
      Setup.start_link(
        name: String.to_atom("setup_#{System.unique_integer([:positive])}"),
        root: root,
        ops: ops,
        keep_local_access: true
      )

    assert_receive {:access, :commissioning, nil}
    assert {:ok, :tailscale} = Setup.configure_internet(%{"ip_address" => "dhcp"}, setup)
    assert {:ok, :cluster} = Setup.configure_tailscale("tskey-not-real", setup)
    assert {:ok, :ready} = Setup.configure_cluster(setup)
    refute_receive :disable_access, 1_500

    GenServer.stop(setup)
  end

  test "development mode restores setup access after a commissioned restart", %{ops: ops} do
    root = TestScenario.temporary_root(:local_dashboard_restart)
    on_exit(fn -> File.rm_rf!(root) end)
    :ok = Store.initialize(root)
    :ok = Store.write_network(TestScenario.dhcp(), root)
    :ok = Store.write_phase(:ready, root)

    {:ok, setup} =
      Setup.start_link(
        name: String.to_atom("setup_#{System.unique_integer([:positive])}"),
        root: root,
        ops: ops,
        keep_local_access: true
      )

    assert_receive {:access, :commissioning, "eth0"}
    refute_receive :disable_access
    GenServer.stop(setup)
  end
end

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
      configure_cluster: fn cookie ->
        send(owner, {:cluster_configuration, cookie})
        Store.write_cluster(cookie, root)
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
    %{root: root, setup: setup}
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

  test "the new backend API persists an explicit cluster cookie", %{root: root, setup: setup} do
    cookie = "Valid_cluster-cookie_123"

    assert {:ok, :tailscale} = Setup.configure_internet(%{"ip_address" => "dhcp"}, setup)
    assert {:ok, :cluster} = Setup.configure_tailscale("tskey-not-real", setup)
    assert {:ok, :ready} = Setup.configure_cluster_cookie(cookie, setup)
    assert_receive {:cluster_configuration, ^cookie}
    assert {:ok, ^cookie} = Store.read_cluster(root)
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
end

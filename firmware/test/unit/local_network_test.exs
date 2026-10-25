defmodule NervesGate.Network.LocalTest do
  use ExUnit.Case, async: false
  alias NervesGate.Network.{Local, Policy, Vintage}
  alias NervesGate.{Config, Remote.Sharing}

  setup do
    previous = Application.get_env(:nerves_gate, :local_network_journal)

    path =
      Path.join(
        System.tmp_dir!(),
        "local-network-#{System.unique_integer([:positive])}/lease.json"
      )

    Application.put_env(:nerves_gate, :local_network_journal, path)

    on_exit(fn ->
      File.rm_rf!(Path.dirname(path))

      if previous,
        do: Application.put_env(:nerves_gate, :local_network_journal, previous),
        else: Application.delete_env(:nerves_gate, :local_network_journal)
    end)

    %{path: path}
  end

  defp status do
    interface = fn name, addresses ->
      %{
        name: name,
        present: true,
        state: :configured,
        master: nil,
        addresses: addresses,
        link: true,
        method: "disabled",
        gateway: nil,
        nameservers: []
      }
    end

    %{
      config:
        Config.from_network(%{
          "mode" => "ports",
          "eth0" => %{"role" => "internet", "address" => Config.address_defaults()},
          "eth1" => %{"role" => "application", "address" => nil}
        }),
      trial: nil,
      recovering: false,
      phase: :idle,
      observed: %{
        ports: [
          interface.("eth0", [%{address: "192.0.2.2", prefix_length: 24}]),
          interface.("eth1", [])
        ],
        bridge: interface.("br0", []),
        usb: interface.("usb0", [%{address: "172.31.211.1", prefix_length: 30}]),
        cellular: nil
      }
    }
  end

  test "only an explicitly enabled independent interface can be claimed" do
    assert {:ok, scope} = Local.candidate(status(), "eth1", "192.168.50.2", 24)
    assert scope.cidr == "192.168.50.0/24"

    for interface <- ["eth0", "usb0", "br0", "wwan0", "anything"] do
      assert {:error, _} = Local.candidate(status(), interface, "192.168.50.2", 24)
    end

    assert {:error, _} =
             Local.candidate(
               put_in(status().config["network"]["eth1"], nil),
               "eth1",
               "192.168.50.2",
               24
             )

    assert {:error, _} =
             Local.candidate(%{status() | trial: %{id: "trial"}}, "eth1", "192.168.50.2", 24)

    assert {:error, _} = Local.candidate(%{status() | observed: nil}, "eth1", "192.168.50.2", 24)
  end

  test "claims reject observed overlap, malformed addresses and non-host addresses" do
    for {address, prefix} <- [
          {"192.0.2.10", 24},
          {"172.31.211.2", 30},
          {"192.168.50.0", 24},
          {"192.168.50.255", 24},
          {"invalid", 24},
          {"192.168.50.2", 0},
          {"192.168.50.2", 32}
        ] do
      assert {:error, _} = Local.candidate(status(), "eth1", address, prefix)
    end
  end

  test "ownership is actual PID plus reference; projections contain neither" do
    {:ok, scope} = Local.candidate(status(), "eth1", "192.168.50.2", 24)
    ref = make_ref()
    local = %{Local.lease(scope, self(), :configured) | ref: ref}
    assert Local.owned(local, self(), ref) == :ok
    assert {:error, _} = Local.owned(local, self(), make_ref())
    assert {:error, _} = Local.owned(local, nil, ref)
    assert Local.public(local) == %{interface: "eth1", phase: :configured, error: nil}
    refute inspect(Local.public(local)) =~ "#Reference"
    assert {:error, _} = Policy.available(Map.put(status(), :local, Local.public(local)))
  end

  test "journal startup blocks reuse and cannot silently adopt an existing route", %{path: path} do
    assert Local.load() == nil
    File.mkdir_p!(Path.dirname(path))

    File.write!(
      path,
      Jason.encode!(%{interface: "eth1", address: "192.168.50.2", prefix: 24, route_owned: false})
    )

    assert %{owner: nil, phase: :cleanup_pending, scope: scope} = Local.load()
    assert Local.mark_advertising(scope) == :ok
    assert {:ok, %{route_owned: true}} = Local.read()
    assert {:error, _} = Local.mark_advertising(scope)
    File.write!(path, "invalid")
    assert %{phase: :blocked, error: %{code: "local_journal_invalid"}} = Local.load()
  end

  test "route claim refuses existing advertisements; cleanup preserves unrelated routes" do
    {:ok, scope} = Local.candidate(status(), "eth1", "192.168.50.2", 24)
    params = %{scope: scope, route: scope.cidr}
    routes = ["10.99.0.0/24"]
    assert {:ok, added} = Sharing.change(:sharing_claim, params, routes)
    assert {:error, %{code: "route_in_use"}} = Sharing.change(:sharing_claim, params, added)
    assert Sharing.change(:sharing_disable, params, added) == {:ok, routes}
    assert Sharing.change(:sharing_disable, params, routes) == {:ok, routes}
  end

  test "application enablement round trips without an IP address or Internet route" do
    network = status().config["network"]
    assert {:ok, ^network} = Config.validate_network(network)

    configs =
      Vintage.configurations(network)
      |> Map.new(fn {name, config} -> {name, config.type.normalize(config)} end)

    assert configs["eth1"].ipv4 == %{method: :disabled}
    refute configs["eth1"].nerves_gate_disabled
    assert {:ok, reconstructed} = Vintage.from_configurations(configs)
    assert reconstructed["eth1"] == %{"role" => "application", "address" => nil}
    disabled = Vintage.configurations(%{network | "eth1" => nil}) |> Map.new()
    assert disabled["eth1"].nerves_gate_disabled
  end
end

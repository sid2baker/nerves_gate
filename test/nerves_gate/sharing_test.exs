defmodule NervesGate.SharingTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Equipment.Subnet, Network, Remote}
  alias NervesGate.Remote.Sharing

  @network %{
    "mode" => "ports",
    "eth0" => nil,
    "eth1" => %{
      "role" => "equipment",
      "address" => %{
        "ip_method" => "static",
        "static_ip" => "192.168.50.2",
        "subnet_mask" => "255.255.255.0",
        "gateway" => nil
      }
    }
  }
  @route "192.168.50.0/24"

  defmodule Adapter do
    @behaviour Remote.Adapter
    def snapshot(ctx), do: Remote.Host.snapshot(ctx.host)
    def login_url(_), do: nil

    def execute(:sharing_sync, params, ctx) do
      send(ctx.owner, :route_read)
      Remote.Host.execute(:sharing_sync, params, ctx.host)
    end

    def execute(operation, params, ctx) do
      send(ctx.owner, {:route_operation, self(), operation, params})

      receive do
        :finish -> Remote.Host.execute(operation, params, ctx.host)
        {:result, result} -> result
      end
    end
  end

  setup context do
    remote_host = start_supervised!({Remote.Host, name: nil})

    if context[:cold_start] do
      Remote.Host.simulate(
        %{sharing: %{ready: false, uncertain: []}, advertised_routes: [@route]},
        remote_host
      )
    end

    remote =
      start_supervised!(
        {Remote, name: nil, adapter: {Adapter, %{host: remote_host, owner: self()}}, timeout: 250}
      )

    host = start_supervised!({Network.Host, name: nil})
    Network.Host.save(@network, host)
    opts = [name: __MODULE__, adapter: {Network.Host, host}, remote: remote, poll_ms: 10]
    start_supervised!({Network, opts})
    network = __MODULE__
    [first, second] = Network.Host.snapshot(host).ports
    Network.Host.simulate(%{ports: [first, %{second | link: true}]}, host)

    eventually(fn ->
      Remote.status(remote).sharing.ready and Network.status(network).phase == :idle
    end)

    %{
      remote: remote,
      remote_host: remote_host,
      host: host,
      network: network,
      opts: opts,
      api: [network: network, remote: remote, equipment: nil]
    }
  end

  @tag cold_start: true
  test "startup reads existing routes once without replaying mutations", ctx do
    assert_received :route_read
    assert Remote.status(ctx.remote).advertised_routes == [@route]
    assert {:error, %{code: "sharing_active"}} = NervesGate.network_propose(@network, ctx.api)
    refute_receive :route_read
    refute_receive {:route_operation, _, _, _}
  end

  test("sharing uses the confirmed IPv4 subnet without site IDs or address translation", ctx) do
    status = Network.status(ctx.network)
    {:ok, scope} = Sharing.scope(status)
    assert scope.cidr == @route

    assert {:ok, %{scope: ^scope, route: @route}} =
             Sharing.enable(status, Remote.status(ctx.remote))

    assert NervesGate.status(ctx.api).sharing == %{
             subnet: @route,
             enabled: false,
             other_routes: []
           }

    assert NervesGate.status(ctx.api).actions["equipment.share"].required == []
    assert NervesGate.status(ctx.api).actions["equipment.unshare"].required == []
    refute function_exported?(NervesGate, :equipment_share, 3)
    refute function_exported?(NervesGate, :equipment_unshare, 2)
  end

  test("only a confirmed active dedicated equipment subnet can be shared", ctx) do
    {:ok, id} = Network.propose(@network, ctx.network)
    assert {:error, %{code: "trial_in_progress"}} = NervesGate.equipment_share(ctx.api)
    :ok = Network.cancel(id, ctx.network)
    status = Network.status(ctx.network)

    shared =
      put_in(status, [:config, "network"], %{
        "mode" => "shared",
        "equipment" => @network["eth1"]["address"]
      })

    assert {:error, :sharing_dedicated_only} = Sharing.scope(shared)
    assert {:error, _} = Subnet.build("usb0", @network["eth1"]["address"])
    refute_receive {:route_operation, _, _, _}

    task =
      Task.async(fn ->
        Network.sharing(:sharing_enable, %{route: "0.0.0.0/0"}, ctx.network)
      end)

    assert_receive {:route_operation, worker, :sharing_enable, %{route: @route, scope: scope}}
    assert scope.cidr == @route
    send(worker, :finish)
    assert :ok = Task.await(task)
  end

  test "route writes hold the LAN worker and preserve unrelated advertisements and preferences",
       ctx do
    other = ["10.70.0.0/16", "fd00::/64"]

    Remote.Host.simulate(
      %{advertised_routes: other, accept_dns: false, serve: [:unchanged]},
      ctx.remote_host
    )

    task = Task.async(fn -> NervesGate.equipment_share(ctx.api) end)
    assert_receive {:route_operation, worker, :sharing_enable, %{route: @route}}
    assert Network.status(ctx.network).phase == :sharing

    assert {:error, %{code: "operation_in_progress"}} =
             NervesGate.network_propose(@network, ctx.api)

    assert {:error, %{code: "operation_in_progress"}} =
             NervesGate.equipment_share(ctx.api)

    assert {:error, %{code: "remote_busy"}} = NervesGate.remote_disconnect(ctx.api)
    send(worker, :finish)
    assert :ok = Task.await(task)
    assert Remote.status(ctx.remote).advertised_routes == Enum.sort(other ++ [@route])
    assert Remote.Host.snapshot(ctx.remote_host).serve == [:unchanged]
    assert NervesGate.status(ctx.api).sharing.enabled
    assert NervesGate.status(ctx.api).sharing.other_routes == other
    assert Remote.status(ctx.remote).state == "offline"
    assert {:error, %{code: "sharing_active"}} = NervesGate.network_propose(@network, ctx.api)
    refute NervesGate.status(ctx.api).actions["network.propose"].enabled
    refute NervesGate.status(ctx.api).remote_access.verified
    assert :ok = withdraw(ctx)
    assert Remote.status(ctx.remote).advertised_routes == other
    refute NervesGate.status(ctx.api).sharing.enabled
    assert NervesGate.status(ctx.api).sharing.other_routes == other
    assert {:error, %{code: "sharing_active"}} = NervesGate.network_propose(@network, ctx.api)
    Remote.Host.simulate(%{advertised_routes: []}, ctx.remote_host)
    assert {:ok, id} = NervesGate.network_propose(@network, ctx.api)
    assert :ok = NervesGate.network_cancel(id, ctx.api)
  end

  test "sharing does not stop a running VPN", ctx do
    :ok = Remote.Host.execute(:connect, %{hostname: "running-gateway"}, ctx.remote_host)
    before = Remote.status(ctx.remote)
    task = Task.async(fn -> NervesGate.equipment_share(ctx.api) end)
    assert_receive {:route_operation, worker, :sharing_enable, _}
    send(worker, :finish)
    assert :ok = Task.await(task)
    assert :ok = withdraw(ctx)
    assert Remote.status(ctx.remote) == before
  end

  test "unknown mutation is not cleared by empty observations or unrelated successful commands",
       ctx do
    task = Task.async(fn -> NervesGate.equipment_share(ctx.api) end)
    assert_receive {:route_operation, worker, :sharing_enable, params}
    assert {:error, %{code: "sharing_unknown"}} = Task.await(task)
    refute Process.alive?(worker)
    assert Remote.status(ctx.remote).advertised_routes == []
    assert Remote.status(ctx.remote).sharing.uncertain == [@route]
    assert NervesGate.status(ctx.api).sharing.enabled == nil
    assert {:error, %{code: "sharing_unknown"}} = NervesGate.network_propose(@network, ctx.api)
    :ok = NervesGate.remote_configure("still-unknown", ctx.api)
    assert_receive {:route_operation, rename, :configure, _}
    send(rename, :finish)
    eventually(fn -> Remote.status(ctx.remote).operation == nil end)
    assert {:error, %{code: "sharing_unknown"}} = NervesGate.equipment_share(ctx.api)
    # Model a Controller write accepted before timeout but committed afterward.
    {:ok, _} = Remote.Host.execute(:sharing_enable, params, ctx.remote_host)
    assert :ok = withdraw(ctx)
    assert Remote.status(ctx.remote).sharing.uncertain == []
    assert Remote.status(ctx.remote).advertised_routes == []
  end

  test("turning sharing off needs neither a ready link nor an online account", ctx) do
    other = "10.70.0.0/16"
    Remote.Host.simulate(%{advertised_routes: [@route, other]}, ctx.remote_host)
    [first, second] = Network.Host.snapshot(ctx.host).ports
    Network.Host.simulate(%{ports: [first, %{second | link: false}]}, ctx.host)
    assert NervesGate.status(ctx.api).sharing.enabled
    assert {:error, %{code: "equipment_not_ready"}} = NervesGate.equipment_share(ctx.api)
    assert :ok = withdraw(ctx)
    assert Remote.status(ctx.remote).advertised_routes == [other]
    refute NervesGate.status(ctx.api).sharing.enabled
    assert :ok = withdraw(ctx)
    assert Remote.status(ctx.remote).advertised_routes == [other]
  end

  test(
    "external routes including legacy advertisements are left alone and block LAN changes",
    ctx
  ) do
    legacy = "fd7a:115c:a1e0:b1a:0:7:c0a8:3200/120"
    Remote.Host.simulate(%{advertised_routes: [legacy]}, ctx.remote_host)
    assert {:error, %{code: "sharing_active"}} = NervesGate.network_propose(@network, ctx.api)
    assert :ok = withdraw(ctx)
    assert Remote.status(ctx.remote).advertised_routes == [legacy]
    assert NervesGate.status(ctx.api).sharing.other_routes == [legacy]
    assert {:error, %{code: "sharing_active"}} = NervesGate.network_propose(@network, ctx.api)
  end

  test "runtime restart does not replay a mutation and its surviving daemon worker cannot change the LAN",
       ctx do
    task = Task.async(fn -> NervesGate.equipment_share(ctx.api) end)
    assert_receive {:route_operation, remote_worker, :sharing_enable, _}
    old = Process.whereis(ctx.network)
    Process.exit(old, :kill)
    assert {:error, %{code: "outcome_unknown"}} = Task.await(task)
    eventually(fn -> Process.whereis(ctx.network) not in [nil, old] end)
    assert Network.status(ctx.network).config["network"] == @network
    assert {:error, %{code: "sharing_unknown"}} = NervesGate.network_propose(@network, ctx.api)
    send(remote_worker, :finish)
    eventually(fn -> Remote.status(ctx.remote).advertised_routes == [@route] end)
    assert Network.status(ctx.network).config["network"] == @network
    assert {:error, %{code: "sharing_active"}} = NervesGate.network_propose(@network, ctx.api)
    refute_receive {:route_operation, _, :sharing_enable, _}
    assert :ok = withdraw(ctx)
  end

  defp withdraw(ctx) do
    task = Task.async(fn -> NervesGate.equipment_unshare(ctx.api) end)
    assert_receive {:route_operation, worker, :sharing_disable, %{route: @route}}
    send(worker, :finish)
    Task.await(task)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end

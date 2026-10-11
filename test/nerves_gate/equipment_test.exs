defmodule NervesGate.EquipmentTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Config, Equipment, Network}
  alias NervesGate.Equipment.{Host, Labels, Linux, Subnet}
  alias NervesGate.TestNetworkAdapter

  @address %{
    "ip_method" => "static",
    "static_ip" => "192.168.50.2",
    "subnet_mask" => "255.255.255.0",
    "gateway" => nil
  }
  @network %{
    "mode" => "ports",
    "eth0" => %{"role" => "equipment", "address" => @address},
    "eth1" => nil
  }
  @entry %{
    ip: "192.168.50.10",
    mac: "02:11:22:33:44:55",
    last_seen: 1_700_000_000_000,
    source: "simulated"
  }

  defmodule ScanAdapter do
    @behaviour Equipment.Adapter
    @impl true
    def neighbors(scope, ctx), do: Host.neighbors(scope, ctx.host)
    @impl true
    def load_labels(ctx), do: Host.load_labels(ctx.host)
    @impl true
    def save_labels(labels, ctx), do: Host.save_labels(labels, ctx.host)
    @impl true
    def scan(scope, ctx) do
      send(ctx.owner, {:scanning, self(), scope})

      receive do
        :continue -> Host.scan(scope, ctx.host)
        {:return, result} -> result
      end
    end
  end

  setup do
    host = start_supervised!({Network.Host, name: nil})
    :ok = Network.Host.save(@network, host)
    adapter = start_supervised!({TestNetworkAdapter, host: host, owner: self()})

    network =
      start_supervised!(
        {Network,
         name: nil, adapter: {TestNetworkAdapter, adapter}, poll_ms: 20, effect_ms: 1_000}
      )

    equipment_host = start_supervised!({Host, name: nil})
    Host.simulate([@entry], equipment_host)

    opts = [
      name: nil,
      network: network,
      adapter: {ScanAdapter, %{host: equipment_host, owner: self()}},
      poll_ms: 20
    ]

    equipment = start_supervised!({Equipment, opts})
    api = [network: network, remote: nil, equipment: equipment]
    eventually(fn -> Enum.count_until(Equipment.status(equipment).entries, 2) == 1 end)

    %{
      network: network,
      host: host,
      adapter: adapter,
      equipment: equipment,
      equipment_host: equipment_host,
      opts: opts,
      api: api
    }
  end

  test "scope is confirmed, bounded and never USB or a submitted interface", ctx do
    assert {:ok, scope} = Subnet.active(Network.status(ctx.network))
    assert scope.interface == "eth0"
    assert scope.cidr == "192.168.50.0/24"
    assert Enum.count_until(Subnet.scan(scope).addresses, 254) == 253
    refute Subnet.host?(scope, scope.address)
    refute Subnet.host?(scope, "192.168.50.0")
    refute Subnet.host?(scope, "192.168.50.255")
    refute Subnet.host?(scope, "192.168.51.10")
    assert {:error, _} = Subnet.build("usb0", @address)
    assert {:ok, wide} = Subnet.build("eth1", %{@address | "subnet_mask" => "255.0.0.0"})
    assert Subnet.scan(wide).cidr == scope.cidr
    assert Subnet.scan(wide).addresses == Subnet.scan(scope).addresses
    assert {:ok, small} = Subnet.build("br0", %{@address | "subnet_mask" => "255.255.255.252"})
    assert Subnet.scan(small).addresses == ["192.168.50.1"]
  end

  test "scan locks LAN proposals and duplicate scans while preserving responsive reads", ctx do
    calls = TestNetworkAdapter.calls(ctx.adapter)
    task = Task.async(fn -> NervesGate.equipment_scan(ctx.api) end)
    assert_receive {:scanning, worker, scope}
    assert scope.interface == "eth0"
    assert Equipment.status(ctx.equipment).operation == :scan
    assert Network.status(ctx.network).phase == :scan

    assert {:error, %{code: "operation_in_progress"}} =
             NervesGate.network_propose(@network, ctx.api)

    assert {:error, %{code: "operation_in_progress"}} = NervesGate.equipment_scan(ctx.api)
    send(worker, :continue)
    assert :ok = Task.await(task)
    assert Equipment.status(ctx.equipment).last_scan
    assert Network.status(ctx.network).phase == :idle
    assert TestNetworkAdapter.calls(ctx.adapter) == calls
  end

  test "scan failures and deadlines never restore or change saved LAN settings", ctx do
    calls = TestNetworkAdapter.calls(ctx.adapter)

    for outcome <- [:failure, :timeout] do
      task = Task.async(fn -> NervesGate.equipment_scan(ctx.api) end)
      assert_receive {:scanning, worker, _}
      ref = Process.monitor(worker)
      if outcome == :failure, do: send(worker, {:return, {:error, :eacces}})
      assert {:error, _} = Task.await(task)
      assert_receive {:DOWN, ^ref, :process, ^worker, _}, 1_500
      eventually(fn -> Equipment.status(ctx.equipment).operation == nil end)
      assert Network.status(ctx.network).phase == :idle
      refute Network.status(ctx.network).recovering
      assert TestNetworkAdapter.calls(ctx.adapter) == calls
      assert Network.Host.load(ctx.host) == {:ok, Config.from_network(@network)}
    end
  end

  test "a disconnected, displaced or unconfirmed interface cannot send probes", ctx do
    observed = Network.Host.snapshot(ctx.host)
    [equipment | rest] = observed.ports

    for port <- [
          %{equipment | link: false},
          %{equipment | present: false},
          %{equipment | master: "br0"},
          %{equipment | addresses: []}
        ] do
      Network.Host.simulate(%{ports: [port | rest]}, ctx.host)
      assert {:error, %{code: "equipment_not_ready"}} = NervesGate.equipment_scan(ctx.api)
    end

    Network.Host.simulate(%{}, ctx.host)
    {:ok, id} = Network.propose(@network, ctx.network)
    assert {:error, %{code: "trial_in_progress"}} = NervesGate.equipment_scan(ctx.api)
    assert NervesGate.status(ctx.api).equipment.entries == []
    assert :ok = Network.cancel(id, ctx.network)
    refute_receive {:scanning, _, _}
  end

  test "labels survive domain restarts but never follow a replacement MAC or another subnet",
       ctx do
    [entry] = Equipment.status(ctx.equipment).entries
    assert :ok = NervesGate.equipment_label(entry.id, "  Pump 1  ", ctx.api)
    stop_supervised!(Equipment)
    equipment = start_supervised!({Equipment, ctx.opts})
    eventually(fn -> match?([%{label: "Pump 1"}], Equipment.status(equipment).entries) end)

    Host.simulate(
      [%{@entry | ip: "192.168.50.11"}, %{@entry | mac: "02:11:22:33:44:66"}],
      ctx.equipment_host
    )

    eventually(fn -> Enum.count_until(Equipment.status(equipment).entries, 4) == 3 end)

    assert Enum.find(Equipment.status(equipment).entries, &(&1.ip == "192.168.50.11")).label ==
             "Pump 1"

    assert Enum.find(Equipment.status(equipment).entries, &(&1.mac == "02:11:22:33:44:66")).label ==
             ""

    changed = put_in(@network, ["eth0", "address", "static_ip"], "192.168.51.2")
    {:ok, id} = Network.propose(changed, ctx.network)
    :ok = Network.confirm(id, ctx.network)
    assert NervesGate.status(Keyword.put(ctx.api, :equipment, equipment)).equipment.entries == []
    eventually(fn -> Equipment.status(equipment).entries == [] end)
    assert {:error, :equipment_changed} = Equipment.label(entry.id, "Wrong network", equipment)
  end

  test "passive observations are filtered and last-seen never becomes poll time", ctx do
    Host.simulate(
      [
        %{@entry | last_seen: nil},
        %{@entry | ip: "10.13.0.2"},
        %{@entry | ip: "192.168.50.0"},
        %{@entry | mac: "ff:ff:ff:ff:ff:ff"}
      ],
      ctx.equipment_host
    )

    send(ctx.equipment, :poll)
    Process.sleep(40)
    assert [entry] = Equipment.status(ctx.equipment).entries
    assert entry.last_seen == @entry.last_seen
    assert entry.label == ""
    refute_receive {:scanning, _, _}
  end

  test "inventory is bounded even when many MACs claim one address", ctx do
    entries =
      for n <- 1..400 do
        %{
          @entry
          | mac:
              "02:11:22:33:#{n |> div(256) |> Integer.to_string(16) |> String.pad_leading(2, "0")}:#{n |> rem(256) |> Integer.to_string(16) |> String.pad_leading(2, "0")}"
        }
      end

    Host.simulate(entries, ctx.equipment_host)
    eventually(fn -> Enum.count_until(Equipment.status(ctx.equipment).entries, 257) == 256 end)
    assert Jason.encode!(NervesGate.status(ctx.api))
  end

  test "a network runtime restart kills the active socket owner", ctx do
    task = Task.async(fn -> NervesGate.equipment_scan(ctx.api) end)
    assert_receive {:scanning, worker, _}
    monitor = Process.monitor(worker)
    Process.exit(Network.runtime(ctx.network), :kill)
    assert_receive {:DOWN, ^monitor, :process, ^worker, _}
    assert {:error, %{code: "outcome_unknown"}} = Task.await(task)
    eventually(fn -> Equipment.status(ctx.equipment).operation == nil end)
    eventually(fn -> Network.runtime(ctx.network) != nil end)
    assert Network.status(ctx.network).config == Config.from_network(@network)
  end

  test "invalid labels and unknown IDs have no persistence effects", ctx do
    [entry] = Equipment.status(ctx.equipment).entries

    for value <- [nil, <<255>>, String.duplicate("x", 65), "bad\nlabel", %{label: "x"}] do
      assert {:error, %{code: "invalid_label"}} =
               NervesGate.equipment_label(entry.id, value, ctx.api)
    end

    assert {:error, %{code: "equipment_changed"}} =
             NervesGate.equipment_label("old", "No", ctx.api)

    assert Host.load_labels(ctx.equipment_host) == {:ok, %{}}
    assert :ok = Equipment.label(entry.id, "Valid", ctx.equipment)
    assert :ok = Equipment.label(entry.id, "", ctx.equipment)
    assert Host.load_labels(ctx.equipment_host) == {:ok, %{}}
  end

  @tag tmp_dir: true
  test "label file roundtrip rejects malformed, oversized and unbounded data", %{tmp_dir: dir} do
    path = Path.join(dir, "labels.json")
    key = String.duplicate("a", 64)
    assert Labels.load(path) == {:ok, %{}}
    assert :ok = Labels.save(%{key => "Pump"}, path)
    assert Labels.load(path) == {:ok, %{key => "Pump"}}

    for data <- [
          "{",
          "[]",
          Jason.encode!(%{"bad key" => "x"}),
          Jason.encode!(%{key => "bad\nlabel"}),
          String.duplicate("x", 131_073)
        ] do
      File.write!(path, data)
      assert {:error, :labels_unavailable} = Labels.load(path)
      assert File.read!(path) == data
    end

    full = Map.new(1..256, &{to_string(&1), "label"})
    assert {:error, :label_limit} = Labels.put(full, "257", "new")
    assert {:ok, _} = Labels.put(full, "1", "replacement")
  end

  @tag tmp_dir: true
  test "unreadable saved labels block writes rather than silently overwriting", %{tmp_dir: dir} do
    # Persistence codec is fail-closed; the owner keeps labels_error until restart.
    path = Path.join(dir, "labels.json")
    File.mkdir!(path)
    assert {:error, :labels_unavailable} = Labels.load(path)
  end

  test "ARP and netlink codecs reject unrelated or malformed data" do
    {:ok, scope} = Subnet.build("eth1", @address)
    {:ok, mac} = Linux.parse_mac(@entry.mac)
    request = Linux.request(mac, {192, 168, 50, 2}, {192, 168, 50, 10})
    assert byte_size(request) == 42
    assert Linux.reply(request, scope) == nil

    reply =
      <<0::96, 0x0806::16, 1::16, 0x0800::16, 6, 4, 2::16, mac::binary, 192, 168, 50, 10, 0::48,
        192, 168, 50, 2>>

    assert %{ip: "192.168.50.10", source: "ARP reply"} = Linux.reply(reply, scope)
    assert Linux.reply(reply, %{scope | address: "192.168.50.3"}) == nil
    assert Linux.reply(<<0, 1>>, scope) == nil

    for value <- ["01:00:00:00:00:00", "00:00:00:00:00:00", "bad", nil],
        do: assert({:error, :invalid_mac} = Linux.parse_mac(value))

    assert Linux.neighbor(<<2, 0::24, 5::native-32, 32::native-16, 0::16>>, 5, 0) == nil
  end

  defp eventually(fun, remaining \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, remaining) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, remaining - 1)
        )
  end
end

defmodule Workbench.DiscoveryTest do
  use ExUnit.Case, async: true

  test "only public Nerves Gate advertisements with usable IPv4 addresses are projected" do
    result = %{
      product: "Nerves Gate",
      name: "controller",
      platform: "ec100",
      version: "0.2.0",
      addresses: [{192, 168, 1, 42}, {127, 0, 0, 1}, {239, 1, 1, 1}],
      cookie: "private"
    }

    assert [device] =
             Workbench.LANDiscovery.devices([
               result,
               result,
               %{result | product: "Other Nerves device"}
             ])

    assert device.address == "192.168.1.42"
    assert device.target == "ec100"
    assert device.url == "http://192.168.1.42:4000/"
    refute Map.has_key?(device, :cookie)
    refute inspect(device) =~ "private"
    assert Workbench.LANDiscovery.devices([%{result | addresses: []}]) == []
  end

  test "refresh is coalesced and enriches manual entries without losing them" do
    from = {self(), make_ref()}
    {:ok, state} = Workbench.LANDiscovery.init(nil)
    {:reply, :ok, state} = Workbench.LANDiscovery.handle_call({:add, "192.168.1.42"}, from, state)
    ref = make_ref()
    state = %{state | task: %{ref: ref}}
    assert {:reply, :ok, ^state} = Workbench.LANDiscovery.handle_call(:refresh, from, state)

    devices =
      Workbench.LANDiscovery.devices([
        %{
          product: "Nerves Gate",
          name: "controller",
          addresses: [{192, 168, 1, 42}],
          platform: "ec100"
        }
      ])

    assert {:noreply, ready} = Workbench.LANDiscovery.handle_info({ref, {devices, nil}}, state)
    assert ready.task == nil
    assert [%{source: :mdns, target: "ec100"}] = ready.view.devices
    assert {:noreply, missing} = Workbench.LANDiscovery.handle_info({ref, {[], nil}}, state)
    assert [%{source: :manual}] = missing.view.devices
  end

  test "explicit SSH observations enrich manual entries, survive discovery and exclude secrets" do
    from = {self(), make_ref()}
    {:ok, state} = Workbench.LANDiscovery.init(nil)

    {:reply, :ok, state} =
      Workbench.LANDiscovery.handle_call({:add, "ec100.example.ts.net"}, from, state)

    identity = %{
      "target" => "ec100",
      "version" => "0.2.0-dev",
      "architecture" => "arm",
      "serial" => "serial-42",
      "cookie" => "secret",
      "private_key" => "secret"
    }

    assert {:reply, :ok, state} =
             Workbench.LANDiscovery.handle_call(
               {:identity, "ec100.example.ts.net", identity},
               from,
               state
             )

    assert [device] = state.view.devices
    assert device.target == "ec100"
    assert device.version == "0.2.0-dev"
    assert device.source == :manual
    assert device.identity.values["serial"] == "serial-42"
    assert {:ok, _, _} = DateTime.from_iso8601(device.identity.read_at)
    refute inspect(state.view) =~ "secret"

    ref = make_ref()

    assert {:noreply, ready} =
             Workbench.LANDiscovery.handle_info({ref, {[], nil}}, %{state | task: %{ref: ref}})

    assert [^device] = ready.view.devices

    assert {:reply, {:error, _}, ^ready} =
             Workbench.LANDiscovery.handle_call({:identity, "other.local", identity}, from, ready)
  end

  test "fresh USB observations survive discovery, exclude secrets and invalidate stale SSH identity" do
    from = {self(), make_ref()}
    {:ok, state} = Workbench.LANDiscovery.init(nil)
    {:reply, :ok, state} = Workbench.LANDiscovery.handle_call({:add, "172.31.211.1"}, from, state)

    {:reply, :ok, state} =
      Workbench.LANDiscovery.handle_call(
        {:identity, "172.31.211.1", %{"version" => "old", "serial" => "old-serial"}},
        from,
        state
      )

    info = %{
      address: "172.31.211.1",
      version: "new",
      target: "ec100",
      runtime: "Elixir 1.20 · OTP 29",
      read_at: "2026-10-22T12:00:00Z",
      interface: "enxusb",
      cookie: "private",
      html: "private"
    }

    assert {:reply, :ok, state} = Workbench.LANDiscovery.handle_call({:usb, info}, from, state)
    assert [device] = state.view.devices
    assert device.source == :usb
    assert device.version == "new"
    assert device.usb_info.runtime == info.runtime
    refute device[:identity]
    refute inspect(state.view) =~ "private"
    refute inspect(state.view) =~ "old-serial"
    assert [directory] = Workbench.Devices.list(%{lifecycle: %{devices: []}}, state.view)
    assert directory.status == "USB information read"

    ref = make_ref()
    mdns = [%{device | source: :mdns, version: "old"} |> Map.delete(:usb_info)]

    assert {:noreply, refreshed} =
             Workbench.LANDiscovery.handle_info({ref, {mdns, nil}}, %{state | task: %{ref: ref}})

    assert [^device] = refreshed.view.devices
  end

  test "information attempts are sticky across disappearance, refresh and manual re-add" do
    {:ok, state} = Workbench.LANDiscovery.init(nil)
    address = "nerves-gate.example.ts.net"
    {:reply, :ok, state} = Workbench.LANDiscovery.handle_call({:add, address}, nil, state)
    assert [device] = state.view.devices
    assert Workbench.Devices.needs_info?(device)

    {:reply, :ok, state} =
      Workbench.LANDiscovery.handle_call({:read, address, :reading, nil}, nil, state)

    assert [device] = state.view.devices
    refute Workbench.Devices.needs_info?(device)

    {:reply, :ok, state} =
      Workbench.LANDiscovery.handle_call(
        {:read, address, :failed, "SSH connection refused"},
        nil,
        state
      )

    ref = make_ref()

    {:noreply, state} =
      Workbench.LANDiscovery.handle_info({ref, {[], nil}}, %{state | task: %{ref: ref}})

    {:reply, :ok, state} = Workbench.LANDiscovery.handle_call({:add, address}, nil, state)
    assert [device] = state.view.devices
    assert device.info_read.status == :failed
    refute Workbench.Devices.needs_info?(device)

    {:reply, :ok, state} =
      Workbench.LANDiscovery.handle_call(
        {:identity, address, %{"target" => "ec100", "version" => "new"}},
        nil,
        state
      )

    assert [device] = state.view.devices
    assert device.info_read.status == :succeeded
    assert device.target == "ec100"
    refute Workbench.Devices.needs_info?(device)
  end

  test "tailnet discovery only projects online gateway names and public endpoints" do
    peer = %{
      "DNSName" => "nerves-gate.tail40465.ts.net.",
      "Online" => true,
      "PrivateKey" => "secret"
    }

    status = %{
      "Peer" => %{
        "a" => peer,
        "b" => %{peer | "DNSName" => "laptop.example.ts.net"},
        "c" => %{peer | "Online" => false}
      }
    }

    assert [device] = Workbench.LANDiscovery.tailnet_devices(status)
    assert device.address == "nerves-gate.tail40465.ts.net"
    assert device.url == "https://nerves-gate.tail40465.ts.net/"
    assert device.source == :tailnet
    refute inspect(device) =~ "secret"
    assert Workbench.LANDiscovery.tailnet_devices(%{}) == []
  end

  test "a bare manual hostname gains the discovered HTTPS endpoint" do
    {:ok, state} = Workbench.LANDiscovery.init(nil)
    address = "nerves-gate.example.ts.net"
    {:reply, :ok, state} = Workbench.LANDiscovery.handle_call({:add, address}, nil, state)

    [candidate] =
      Workbench.LANDiscovery.tailnet_devices(%{
        "Peer" => %{"a" => %{"DNSName" => address, "Online" => true}}
      })

    ref = make_ref()

    assert {:noreply, ready} =
             Workbench.LANDiscovery.handle_info({ref, {[candidate], nil}}, %{
               state
               | task: %{ref: ref}
             })

    assert [%{url: "https://nerves-gate.example.ts.net/", source: :tailnet}] = ready.view.devices
  end

  test "explicit HTTPS endpoints survive discovery while gaining advertised metadata" do
    {:ok, state} = Workbench.LANDiscovery.init(nil)
    url = "https://nerves-gate.example.ts.net/"
    {:reply, :ok, state} = Workbench.LANDiscovery.handle_call({:add, url}, nil, state)
    [device] = state.view.devices

    advertised = %{
      device
      | source: :mdns,
        target: "ec100",
        url: "http://nerves-gate.example.ts.net:4000/"
    }

    ref = make_ref()

    assert {:noreply, ready} =
             Workbench.LANDiscovery.handle_info({ref, {[advertised], "Tailnet unavailable"}}, %{
               state
               | task: %{ref: ref}
             })

    assert [%{url: ^url, target: "ec100"}] = ready.view.devices
    assert ready.view.error == "Tailnet unavailable"
  end

  test "manual addresses and root URLs are unverified and never retain secrets" do
    assert {:ok, %{address: "192.168.1.42", source: :manual}} =
             Workbench.LANDiscovery.manual(" 192.168.1.42 ")

    for host <- ["ec100.example.ts.net", "device.local", "ec100"] do
      assert {:ok, %{address: ^host, url: url}} = Workbench.LANDiscovery.manual(host)
      assert url == "http://#{host}:4000/"
    end

    assert {:ok, "ec100.example.ts.net"} = Workbench.LANDiscovery.host(" EC100.example.ts.net. ")
    assert {:error, _} = Workbench.LANDiscovery.host("https://device.example/")

    for url <- ["https://nerves-gate.tail40465.ts.net/", "http://192.168.1.42:4001/"] do
      assert {:ok, %{url: ^url}} = Workbench.LANDiscovery.manual(url)
    end

    for address <- [
          nil,
          "https://user:secret@device.example/",
          "https://device.example/login/secret",
          "https://device.example/?token=secret",
          "https://device.example/#secret",
          "https://device.example:0/",
          "https://device.example:65536/",
          "127.0.0.1",
          "224.0.0.251",
          "0.0.0.0",
          "999.0.0.1",
          "--proxycommand=bad",
          "bad..hostname",
          "ssh://ec100.example.ts.net",
          "device.example:22",
          "192.168.1.1;reboot"
        ] do
      assert {:error, _} = Workbench.LANDiscovery.manual(address)
    end
  end
end

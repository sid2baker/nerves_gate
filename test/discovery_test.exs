defmodule Dev.DiscoveryTest do
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
             Dev.Discovery.devices([result, result, %{result | product: "Other Nerves device"}])

    assert device.address == "192.168.1.42"
    assert device.target == "ec100"
    assert device.url == "http://192.168.1.42:4000/"
    refute Map.has_key?(device, :cookie)
    refute inspect(device) =~ "private"
    assert Dev.Discovery.devices([%{result | addresses: []}]) == []
  end

  test "refresh is coalesced and enriches manual entries without losing them" do
    from = {self(), make_ref()}
    {:ok, state} = Dev.Discovery.init(nil)
    {:reply, :ok, state} = Dev.Discovery.handle_call({:add, "192.168.1.42"}, from, state)
    ref = make_ref()
    state = %{state | task: %{ref: ref}}
    assert {:reply, :ok, ^state} = Dev.Discovery.handle_call(:refresh, from, state)

    devices =
      Dev.Discovery.devices([
        %{
          product: "Nerves Gate",
          name: "controller",
          addresses: [{192, 168, 1, 42}],
          platform: "ec100"
        }
      ])

    assert {:noreply, ready} = Dev.Discovery.handle_info({ref, devices}, state)
    assert ready.task == nil
    assert [%{source: :mdns, target: "ec100"}] = ready.view.devices
    assert {:noreply, missing} = Dev.Discovery.handle_info({ref, []}, state)
    assert [%{source: :manual}] = missing.view.devices
  end

  test "explicit SSH observations enrich manual entries, survive discovery and exclude secrets" do
    from = {self(), make_ref()}
    {:ok, state} = Dev.Discovery.init(nil)
    {:reply, :ok, state} = Dev.Discovery.handle_call({:add, "ec100.example.ts.net"}, from, state)

    identity = %{
      "target" => "ec100",
      "version" => "0.2.0-dev",
      "architecture" => "arm",
      "serial" => "serial-42",
      "cookie" => "secret",
      "private_key" => "secret"
    }

    assert {:reply, :ok, state} =
             Dev.Discovery.handle_call({:identity, "ec100.example.ts.net", identity}, from, state)

    assert [device] = state.view.devices
    assert device.target == "ec100"
    assert device.version == "0.2.0-dev"
    assert device.source == :manual
    assert device.identity.values["serial"] == "serial-42"
    assert {:ok, _, _} = DateTime.from_iso8601(device.identity.read_at)
    refute inspect(state.view) =~ "secret"

    ref = make_ref()
    assert {:noreply, ready} = Dev.Discovery.handle_info({ref, []}, %{state | task: %{ref: ref}})
    assert [^device] = ready.view.devices

    assert {:reply, {:error, _}, ^ready} =
             Dev.Discovery.handle_call({:identity, "other.local", identity}, from, ready)
  end

  test "fresh USB observations survive discovery, exclude secrets and invalidate stale SSH identity" do
    from = {self(), make_ref()}
    {:ok, state} = Dev.Discovery.init(nil)
    {:reply, :ok, state} = Dev.Discovery.handle_call({:add, "172.31.211.1"}, from, state)

    {:reply, :ok, state} =
      Dev.Discovery.handle_call(
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

    assert {:reply, :ok, state} = Dev.Discovery.handle_call({:usb, info}, from, state)
    assert [device] = state.view.devices
    assert device.source == :usb
    assert device.version == "new"
    assert device.usb_info.runtime == info.runtime
    refute device[:identity]
    refute inspect(state.view) =~ "private"
    refute inspect(state.view) =~ "old-serial"
    assert [directory] = Dev.Devices.list(%{lifecycle: %{devices: []}}, state.view)
    assert directory.status == "USB information read"

    ref = make_ref()
    mdns = [%{device | source: :mdns, version: "old"} |> Map.delete(:usb_info)]

    assert {:noreply, refreshed} =
             Dev.Discovery.handle_info({ref, mdns}, %{state | task: %{ref: ref}})

    assert [^device] = refreshed.view.devices
  end

  test "manual addresses are unverified data, never URLs or control commands" do
    assert {:ok, %{address: "192.168.1.42", source: :manual}} =
             Dev.Discovery.manual(" 192.168.1.42 ")

    for host <- ["ec100.example.ts.net", "device.local", "ec100"] do
      assert {:ok, %{address: ^host, url: url}} = Dev.Discovery.manual(host)
      assert url == "http://#{host}:4000/"
    end

    assert {:ok, "ec100.example.ts.net"} = Dev.Discovery.host(" EC100.example.ts.net. ")

    for address <- [
          nil,
          "http://192.168.1.42/",
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
      assert {:error, _} = Dev.Discovery.manual(address)
    end
  end
end

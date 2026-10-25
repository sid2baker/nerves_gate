defmodule Workbench.FactoryConnectionTest do
  use ExUnit.Case, async: true
  alias Workbench.FactoryConnection, as: Connection
  require Phoenix.LiveViewTest

  @tag :tmp_dir
  test "captures full USB topology from the reviewed Rockchip location, not a device number", %{
    tmp_dir: root
  } do
    usb(root, "1-2.5", "1", "2.5")
    usb(root, "2-5", "2", "5")
    assert Connection.usb_path("105", root) == "1-2.5"
    assert Connection.usb_path("205", root) == "2-5"
    assert Connection.usb_path("106", root) == nil
    usb(root, "1-5", "1", "5")
    assert Connection.usb_path("105", root) == nil
  end

  @tag :tmp_dir
  test "only an addressed, running /30 on the exact reviewed USB topology yields a peer", %{
    tmp_dir: root
  } do
    File.mkdir!(Path.join(root, "enxusb"))
    File.ln_s!("../../../1-2.5/1-2.5:1.0", Path.join([root, "enxusb", "device"]))
    assert Connection.usb_paths(root) == ["1-2.5"]
    usb = address(~c"enxusb", {172, 31, 211, 2}, {255, 255, 255, 252})
    [peer] = Connection.peers([usb], "1-2.5", root)
    assert peer.address == "172.31.211.1"
    assert peer.local == {172, 31, 211, 2}
    assert peer.interface == "enxusb"
    assert Connection.peers([usb], "1-5", root) == []
    assert Connection.peers([%{usb | flags: [:up]}], "1-2.5", root) == []
    assert Connection.peers([%{usb | netmask: %{addr: {255, 255, 255, 0}}}], "1-2.5", root) == []
    assert Connection.peers([%{usb | addr: %{addr: {172, 31, 211, 0}}}], "1-2.5", root) == []

    ethernet = address(~c"eth0", {192, 168, 1, 100}, {255, 255, 255, 0})
    assert Connection.peers([usb, ethernet], "1-2.5", root) == [peer]
    overlap = address(~c"eth0", {172, 31, 211, 100}, {255, 255, 255, 0})
    assert Connection.peers([usb, overlap], "1-2.5", root) == []

    other_side = %{usb | addr: %{addr: {172, 31, 211, 1}}}
    assert [%{address: "172.31.211.2"}] = Connection.peers([other_side], "1-2.5", root)
  end

  test "reads only the existing page's firmware, target and runtime, never private HTML" do
    html =
      page("0.3.0-dev", "ec100") <> "<input value='private-token'><script>private-cookie</script>"

    assert {:ok, %{version: "0.3.0-dev", target: "ec100", runtime: "Elixir 1.20 · OTP 29"} = info} =
             Connection.information(html, "0.3.0-dev")

    refute inspect(info) =~ "private"
    assert {:ok, %{version: "0.3.0-dev"}} = Connection.information(html, nil)
    assert {:error, :firmware_mismatch} = Connection.information(page("old", "ec100"), "new")
    assert {:error, :firmware_mismatch} = Connection.information(page("new", "x86_64"), "new")
    assert {:error, :invalid_information} = Connection.information("<h1>Another site</h1>", "new")

    assert {:error, :invalid_information} =
             Connection.information(String.duplicate("x", 1_048_577), "new")
  end

  test "parses a real rendered gateway Settings page without a new firmware API" do
    projection = NervesGate.Projection.disconnected().status

    projection =
      put_in(projection.system, %{projection.system | target: "ec100", firmware: "0.3.0-dev"})

    html =
      Phoenix.LiveViewTest.render_component(&NervesGateWeb.SettingsLive.render/1,
        projection: projection,
        access: nil,
        key_form: Phoenix.Component.to_form(%{"public_key" => ""}, as: :ssh)
      )

    assert {:ok, %{version: "0.3.0-dev", target: "ec100"}} =
             Connection.information(html, "0.3.0-dev")
  end

  test "HTTP reads bind their source, never redirect or retry, and bound discarded page data" do
    opts = Connection.request_options(%{local: {172, 31, 211, 2}}, 500)
    assert opts[:finch][:conn_opts][:transport_opts] == [ip: {172, 31, 211, 2}, timeout: 500]
    assert opts[:retry] == false
    assert opts[:redirect] == false
    assert opts[:raw]
    assert opts[:finch][:receive_timeout] == 500
    assert opts[:finch][:pool_timeout] == 500
    assert opts[:finch][:request_timeout] == 500
    html = page("new", "ec100")

    response =
      Req.get!(
        "http://usb.invalid/settings",
        Keyword.put(opts, :plug, fn conn -> Plug.Conn.send_resp(conn, 200, html) end)
      )

    assert response.status == 200
    assert response.body == html

    response =
      Req.get!(
        "http://usb.invalid/settings",
        Keyword.put(opts, :plug, fn conn ->
          Plug.Conn.send_resp(conn, 200, String.duplicate("x", 1_048_577))
        end)
      )

    assert response.status == 413
    assert response.body == ""
  end

  test "native HTTP transport accepts the source-bound Finch options" do
    html = page("new", "ec100")

    server =
      start_supervised!(
        {Bandit,
         plug: fn conn, _ -> Plug.Conn.send_resp(conn, 200, html) end,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    opts = Connection.request_options(%{local: {127, 0, 0, 1}}, 1_000)
    assert {:ok, %{status: 200, body: ^html}} = Req.get("http://127.0.0.1:#{port}/settings", opts)
  end

  test "wait retries only read-only probes and returns the first matching information" do
    parent = self()
    counter = :atomics.new(1, [])
    info = %{address: "172.31.211.1", version: "new"}

    probe = fn _ ->
      send(parent, :probe)
      if :atomics.add_get(counter, 1, 1) < 3, do: {:error, :usb_not_ready}, else: {:ok, info}
    end

    assert %{status: :connected, device: ^info} = Connection.await(probe, 1_000, 1)
    assert_receive :probe
    assert_receive :probe
    assert_receive :probe
    refute_receive :probe, 0
  end

  test "version mismatch is not accepted or retried" do
    parent = self()

    probe = fn _ ->
      send(parent, :probe)
      {:error, :firmware_mismatch}
    end

    assert %{status: :unavailable, message: message} = Connection.await(probe, 1_000, 1)
    assert message =~ "reviewed EC100 firmware version"
    assert message =~ "Flash verified"
    assert_receive :probe
    refute_receive :probe, 0
  end

  test "deadline also bounds a stuck HTTP probe without changing successful flash outcome" do
    parent = self()

    probe = fn _ ->
      send(parent, {:probe, self()})
      Process.sleep(:infinity)
    end

    assert %{status: :unavailable, message: message} = Connection.await(probe, 30, 1)
    assert message =~ "Flash verified"
    assert message =~ "No flash retry"
    assert_receive {:probe, pid}
    refute Process.alive?(pid)
  end

  test "cancelling the waiting owner also stops its in-flight read" do
    parent = self()

    probe = fn _ ->
      send(parent, {:probe, self()})
      Process.sleep(:infinity)
    end

    {owner, ref} = spawn_monitor(fn -> Connection.await(probe, 5_000) end)
    assert_receive {:probe, pid}
    monitor = Process.monitor(pid)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}
    assert_receive {:DOWN, ^monitor, :process, ^pid, _}
  end

  test "older in-flight reviews without USB topology never scan arbitrary devices" do
    assert %{status: :unavailable, message: message} =
             Connection.wait(%{}, fn _ -> flunk("must not probe") end)

    assert message =~ "could not be tracked"
  end

  defp usb(root, name, bus, port) do
    path = Path.join(root, name)
    File.mkdir!(path)

    for {name, value} <- [
          {"idVendor", "2207"},
          {"idProduct", "350f"},
          {"busnum", bus},
          {"devpath", port}
        ],
        do: File.write!(Path.join(path, name), value <> "\n")
  end

  defp address(name, ip, mask),
    do: %{name: name, flags: [:up, :running], addr: %{addr: ip}, netmask: %{addr: mask}}

  defp page(version, target) do
    Enum.map_join(
      [{"Firmware", version}, {"Target", target}, {"Runtime", "Elixir 1.20 · OTP 29"}],
      fn {label, value} ->
        "<div class='ui-setting-row'><div><h3>#{label}</h3></div><div class='ui-setting-value'>#{value}</div></div>"
      end
    )
  end
end

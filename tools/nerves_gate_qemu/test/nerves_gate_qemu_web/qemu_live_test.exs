defmodule NervesGateQEMUWeb.QemuLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias NervesGateQEMUWeb.QemuLive

  @endpoint NervesGateQEMUWeb.Endpoint

  setup do
    previous = System.get_env("NERVES_GATE_QEMU_STATE")

    root =
      Path.join(System.tmp_dir!(), "nerves_gate_qemu_live_#{System.unique_integer([:positive])}")

    System.put_env("NERVES_GATE_QEMU_STATE", root)

    on_exit(fn ->
      File.rm_rf!(root)

      if previous,
        do: System.put_env("NERVES_GATE_QEMU_STATE", previous),
        else: System.delete_env("NERVES_GATE_QEMU_STATE")
    end)

    :ok
  end

  test "host endpoint does not expose gateway pages" do
    assert get(build_conn(), "/").status == 404
    assert get(build_conn(), "/commissioning").status == 404
    assert get(build_conn(), "/api/status").status == 404
  end

  test "host control plane permits isolated localhost dashboard frames" do
    connection = get(build_conn(), "/dev/qemu")
    [policy] = Plug.Conn.get_resp_header(connection, "content-security-policy")

    assert policy =~ "frame-src http://*.localhost:* http://localhost:*"
    assert policy =~ "frame-ancestors 'none'"
  end

  test "host development route renders the variable topology" do
    {:ok, _view, html} = live(build_conn(), "/dev/qemu")

    assert html =~ "QEMU Test Setup"
    assert html =~ "M01"
    assert html =~ "M02"
    assert html =~ "M03"
    assert html =~ "http://m01.localhost:4001"
    assert html =~ ~s(phx-click="add")
    assert html =~ ~s(phx-click="disconnect")
  end

  test "running devices render isolated dashboard iframes" do
    html =
      render_component(&QemuLive.render/1,
        snapshot: %{
          observed_at: DateTime.utc_now(),
          devices: [running_device()]
        },
        count: 1,
        busy: false,
        operation: nil,
        iframe_revision: 4,
        flash: %{}
      )

    assert html =~ ~s(id="qemu-frame-m01-4")
    assert html =~ ~s(src="http://m01.localhost:4001")
    assert html =~ "M01 NervesGate dashboard"
    assert html =~ "Embedded dashboard"
    assert html =~ "Collapse"
  end

  defp running_device do
    %{
      id: "M01",
      slug: "m01",
      port: 4001,
      iframe_url: "http://m01.localhost:4001",
      status_url: "http://127.0.0.1:4001/api/status",
      vm: :running,
      link: :up,
      fault: :none,
      configured: true,
      internet: :online,
      tailnet: :online,
      cluster: :online,
      tailnet_ip: "100.64.0.1",
      daemon: "running",
      replicas: 2,
      connected_replicas: 2,
      stale_replicas: 0,
      alarms: [],
      error: nil
    }
  end
end

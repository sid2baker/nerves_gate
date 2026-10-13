defmodule NervesGateWeb.DistributedBackendTest do
  use ExUnit.Case, async: false

  @backend NervesGateWeb.Backend

  test "local mode preserves the existing API" do
    assert @backend.status() == NervesGate.status()
    assert @backend.distribution_cookie() == NervesGate.distribution_cookie()
  end

  test "workstation startup requires a device backend" do
    {peer, _} = start_peer(nil, :unused)
    configure(peer)
    call(peer, Application, :put_env, [:nerves_gate, :target, :host])
    call(peer, Application, :put_env, [:nerves_gate, :backend_node, nil])
    call(peer, Code, :compiler_options, [[ignore_module_conflict: true]])
    call(peer, Code, :compile_file, [Path.expand("lib/nerves_gate/application.ex")])

    assert_raise RuntimeError, ~r/Host mode requires a device backend/, fn ->
      call(peer, NervesGate.Application, :start, [:normal, []])
    end
  end

  @tag :development_cookie
  test "the compiled development cookie applies to existing and newly started nodes" do
    System.cmd("epmd", ["-daemon"])

    for cookie <- [:mycookie, nil] do
      suffix = System.unique_integer([:positive])
      name = "gateway_cookie_#{suffix}"
      node = :"#{name}@127.0.0.1"
      {peer, _} = start_peer(if(cookie, do: nil, else: name), :original_test_cookie)
      configure(peer)
      call(peer, Application, :put_env, [:nerves_gate, :distribution_cookie, cookie])
      call(peer, Application, :put_env, [:nerves_gate, :development_node, node])
      call(peer, Code, :compiler_options, [[ignore_module_conflict: true]])
      call(peer, Code, :compile_file, [Path.expand("lib/nerves_gate/distribution.ex")])

      if cookie do
        refute call(peer, Node, :alive?, [])
        call(peer, Application, :put_env, [:nerves_gate, :target, :x86_64])
        assert :ok = call(peer, NervesGate.Distribution, :ensure_started, [%{}])
        assert call(peer, Node, :self, []) == node
        assert call(peer, Node, :get_cookie, []) == :mycookie
        call(peer, Node, :set_cookie, [:original_test_cookie])
      end

      assert :ok = call(peer, NervesGate.Distribution, :configure_cookie, [])
      assert call(peer, Node, :get_cookie, []) == (cookie || :original_test_cookie)

      call(peer, Application, :put_env, [:nerves_gate, :distribution_cookie, :runtime_change])
      assert :ok = call(peer, NervesGate.Distribution, :configure_cookie, [])
      assert call(peer, Node, :get_cookie, []) == (cookie || :original_test_cookie)
    end
  end

  @tag timeout: 60_000
  test "compile-time UI mode uses a separate node, with no local backend or command replay" do
    System.cmd("epmd", ["-daemon"])
    suffix = System.unique_integer([:positive])
    cookie = :"gateway_test_#{suffix}"
    {device, node} = start_peer("gateway_device_#{suffix}", cookie)
    {ui, _} = start_peer("gateway_ui_#{suffix}", cookie)
    configure(device)
    configure(ui)
    assert {:ok, _} = call(device, NervesGate.TestDevice, :start, [])
    call(device, Application, :put_env, [:nerves_gate, :target, :test_device])

    # Compile only the three mode-dependent modules on the UI peer. The device
    # runs the ordinary, unchanged API and the existing test hardware doubles.
    call(ui, Application, :put_env, [:nerves_gate, :backend_node, node])
    call(ui, Code, :compiler_options, [[ignore_module_conflict: true]])

    for path <- [
          "lib/nerves_gate/application.ex",
          "lib/nerves_gate_web/backend.ex",
          "lib/nerves_gate_web/observations.ex"
        ] do
      call(ui, Code, :compile_file, [Path.expand(path)])
    end

    assert {:ok, _} = call(ui, Application, :ensure_all_started, [:nerves_gate])

    for name <- [
          NervesGate.Properties,
          NervesGate.Network,
          NervesGate.Network.Host,
          NervesGate.Remote,
          NervesGate.Equipment,
          NervesGate.Indicators,
          NervesGate.Buses
        ] do
      assert call(ui, Process, :whereis, [name]) == nil
    end

    # Changing application env at runtime cannot switch the compiled UI mode.
    call(ui, Application, :put_env, [:nerves_gate, :backend_node, nil])
    status = call(ui, @backend, :status, [])
    assert status.system.node == node
    assert status.system.target == "test_device"
    assert status.backend.available
    refute Map.has_key?(status.system, :cookie)
    assert {:ok, ^cookie} = call(ui, @backend, :distribution_cookie, [])

    settings = %{"mode" => "shared", "equipment" => NervesGate.Config.address_defaults()}
    access = %{local: {172, 31, 0, 1}, peer: {172, 31, 0, 2}}
    assert {:ok, id} = call(ui, @backend, :network_propose, [settings, [access: access]])
    assert call(device, NervesGate, :status, []).network.pending.id == id
    refute call(device, NervesGate, :status, []).network.setup_completed
    assert :ok = call(ui, @backend, :network_cancel, [id])
    assert call(device, NervesGate, :status, []).network.pending == nil

    # Application exceptions must not be disguised as transport failures.
    assert {:exception, :function_clause, _} =
             catch_error(call(ui, @backend, :network_propose, [settings, [network: %{}]]))

    # An admitted RPC can finish after its caller times out. It is never replayed.
    call(device, :sys, :suspend, [NervesGate.Network])

    try do
      assert {:error, %{code: "outcome_unknown"}} =
               call(ui, @backend, :network_propose, [settings])
    after
      call(device, :sys, :resume, [NervesGate.Network])
    end

    late = call(ui, @backend, :status, []).network.pending.id
    assert :ok = call(ui, @backend, :network_cancel, [late])
    assert call(ui, @backend, :status, []).network.pending == nil

    :peer.stop(device)
    status = call(ui, @backend, :status, [])
    refute status.backend.available
    assert Enum.all?(status.actions, fn {_, action} -> not action.enabled end)
    assert status.system.target == "—"
    assert {:error, %{code: "outcome_unknown"}} = call(ui, @backend, :identify, [])

    # The entire UI still renders; no local simulator substitutes for the device.
    for path <- ["/", "/network", "/remote", "/device", "/distribution", "/equipment"] do
      conn = call(ui, Plug.Test, :conn, [:get, path])
      conn = call(ui, NervesGateWeb.Endpoint, :call, [conn, []])
      assert conn.status == 200
      assert conn.resp_body =~ "backend-disconnected"
    end

    {restarted, ^node} = start_peer("gateway_device_#{suffix}", cookie)
    configure(restarted)
    assert {:ok, _} = call(restarted, NervesGate.TestDevice, :start, [])
    assert call(ui, @backend, :status, []).backend.available
    refute call(restarted, NervesGate, :status, []).indicators.led.identifying
  end

  defp start_peer(name, cookie) do
    opts = %{
      connection: :standard_io,
      args: [~c"+S", ~c"2:2", ~c"-pa" | :code.get_path()]
    }

    opts =
      if name,
        do: Map.merge(opts, %{name: String.to_atom(name), host: ~c"127.0.0.1", longnames: true}),
        else: opts

    {:ok, peer, node} = :peer.start(opts)
    on_exit(fn -> if Process.alive?(peer), do: :peer.stop(peer) end)
    if name, do: call(peer, Node, :set_cookie, [cookie])
    {peer, node}
  end

  defp configure(peer) do
    call(peer, Application, :ensure_all_started, [:elixir])

    for app <- [:nerves_gate, :phoenix] do
      call(peer, Application, :load, [app])

      for {key, value} <- Application.get_all_env(app) do
        call(peer, Application, :put_env, [app, key, value])
      end
    end
  end

  defp call(peer, module, function, args), do: :peer.call(peer, module, function, args, 20_000)
end

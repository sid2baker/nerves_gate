defmodule Simulator.Scenarios.FrontendAssets do
  @moduledoc false
  import ExUnit.Assertions
  alias Simulator.TestQemu, as: Qemu
  alias NervesGateWeb.Endpoint
  alias DevWeb.Endpoint, as: Site
  alias Phoenix.Socket.Transport

  def spec,
    do: %{
      :name => "Simulator site and firmware serve the frontend; firmware needs no Volt runtime"
    }

  def run(%{device: vm}) do
    assert_websocket_csrf()
    assert Qemu.status(vm).system.node == vm.node

    # Independent probes: development error pages may close a keep-alive
    # connection after sending their response. Never retry to conceal failures.
    host =
      Req.new(
        base_url: "http://localhost",
        unix_socket: System.fetch_env!("QEMU_HTTP_SOCKET"),
        headers: [connection: "close"],
        retry: false
      )

    port = String.to_integer(System.fetch_env!("QEMU_HTTP_PORT"))
    assert %URI{scheme: "http", host: "localhost", port: ^port} = URI.parse(Site.url())
    assert Site.config(:http)[:ip] == {:local, System.fetch_env!("QEMU_HTTP_SOCKET")}
    # The session checks the gateway Endpoint's configuration but never serves it.
    refute Phoenix.Endpoint.server?(:nerves_gate, Endpoint)

    firmware =
      Req.new(
        base_url: Qemu.ui_url(vm),
        headers: [connection: "close"],
        retry: false
      )

    assert_assets(host)
    assert_assets(firmware)
    assert_simulator_site(host, vm)
    assert Req.get!(firmware, url: "/tests").status == 404
    assert Req.get!(firmware, url: "/devices/#{vm.id}").status == 404
    assert Req.get!(firmware, url: "/api/state").status == 404

    if System.get_env("QEMU_CI") != "true" do
      browser =
        Req.new(
          base_url: "http://127.0.0.1:#{port}",
          headers: [connection: "close"],
          retry: false
        )

      assert_assets(browser)

      if Site.config(:code_reloader) do
        assert Req.get!(browser, url: "/tidewave/config").body["framework_type"] == "phoenix"

        assert Req.get!(browser,
                 url: "/tidewave/mcp",
                 headers: [origin: "https://untrusted.example"]
               ).status == 403
      end
    end

    # Root discovery must not advertise a different MCP server to bridge clients.
    assert Req.get!(host, url: "/config", redirect: false).status == 404

    # Tidewave owns its JSON parser; the gateway only accepts form bodies.
    # Test/CI hosts and firmware must not expose Tidewave at all.
    if Site.config(:code_reloader) do
      assert Req.get!(host, url: "/tidewave/config").body["framework_type"] == "phoenix"
      assert Req.get!(host, url: "/tidewave/mcp").status == 405

      initialized =
        Req.post!(host,
          url: "/tidewave/mcp",
          json: %{
            jsonrpc: "2.0",
            id: 1,
            method: "initialize",
            params: %{
              protocolVersion: "2025-03-26",
              capabilities: %{},
              clientInfo: %{name: "frontend_assets", version: "1.0"}
            }
          }
        )

      assert initialized.status == 200
      assert initialized.body["id"] == 1
      assert is_map(initialized.body["result"]["serverInfo"])

      assert Req.get!(host,
               url: "/tidewave/mcp",
               headers: [origin: "https://untrusted.example"]
             ).status == 403
    else
      assert Req.get!(host, url: "/tidewave/config").status == 404
      assert Req.get!(host, url: "/tidewave/mcp").status == 404
    end

    assert Req.get!(firmware, url: "/config").status == 404
    assert Req.get!(firmware, url: "/tidewave/mcp").status == 404
    assert :erpc.call(vm.node, :code, :where_is_file, [~c"tidewave.app"]) == :non_existing

    page = Req.get!(firmware, url: "/")
    [csp] = Req.Response.get_header(page, "content-security-policy")
    assert csp =~ "style-src 'self';"
    refute csp =~ "unsafe-inline"
    refute page.body =~ "/@volt/"
    assert Req.get!(firmware, url: "/@volt/client.js").status == 404
    assert :erpc.call(vm.node, :code, :where_is_file, [~c"volt.app"]) == :non_existing

    for path <- ["/assets/js/app.js", "/assets/css/app.css"] do
      response = Req.get!(firmware, url: path)
      assert Req.Response.get_header(response, "cache-control") == ["public, no-cache"]
      [etag] = Req.Response.get_header(response, "etag")
      assert Req.get!(firmware, url: path, headers: [{"if-none-match", etag}]).status == 304
    end
  end

  @doc false
  def assert_websocket_csrf do
    {"/live", Phoenix.LiveView.Socket, socket_opts} =
      List.keyfind(Endpoint.__sockets__(), "/live", 0)

    websocket_opts = Keyword.fetch!(socket_opts, :websocket)
    assert websocket_opts[:check_origin] == false
    assert websocket_opts[:check_csrf] == true
    assert :peer_data in websocket_opts[:connect_info]
    session_opts = Keyword.fetch!(websocket_opts[:connect_info], :session)
    assert session_opts[:same_site] == "Strict"
    assert session_opts[:http_only] == true
    opts = Transport.load_config(websocket_opts)

    {page, token} = csrf_session(session_opts)
    {other_page, _other_token} = csrf_session(session_opts)

    request =
      Plug.Test.conn(:get, "http://gateway.example.ts.net:4000/live/websocket")
      |> Plug.Conn.put_req_header("origin", "https://gateway.example.ts.net")

    refute Transport.check_origin(request, Phoenix.LiveView.Socket, Endpoint, opts).halted

    connect_info = fn page, params ->
      conn = Plug.Conn.fetch_query_params(%{request | query_string: URI.encode_query(params)})
      conn = if page, do: Plug.Test.recycle_cookies(conn, page), else: conn
      Transport.connect_info(conn, Endpoint, opts[:connect_info], opts)
    end

    valid = connect_info.(page, %{"_csrf_token" => token})
    assert valid.session == Plug.Conn.get_session(page)
    assert valid.peer_data == Plug.Conn.get_peer_data(request)

    for {cookie_source, params} <- [
          {page, %{}},
          {page, %{"_csrf_token" => "invalid"}},
          {nil, %{"_csrf_token" => token}},
          {other_page, %{"_csrf_token" => token}}
        ] do
      assert connect_info.(cookie_source, params).session == nil
    end
  end

  defp csrf_session(session_opts) do
    conn = Plug.Test.conn(:get, "/")

    conn =
      %{conn | secret_key_base: Endpoint.config(:secret_key_base)}
      |> Plug.Session.call(Plug.Session.init(session_opts))
      |> Plug.Conn.fetch_session()
      |> Plug.CSRFProtection.call(Plug.CSRFProtection.init([]))

    token = Plug.CSRFProtection.get_csrf_token()
    {Plug.Conn.send_resp(conn, 200, ""), token}
  end

  defp assert_simulator_site(client, vm) do
    overview = Req.get!(client, url: "/").body |> Floki.parse_document!()
    assert [_] = Floki.find(overview, "#workbench-overview")
    assert [] = Floki.find(overview, "form")
    assert [_] = Floki.find(overview, "nav[aria-label='Workbench navigation']")
    simulator = Req.get!(client, url: "/simulator").body |> Floki.parse_document!()
    assert [_] = Floki.find(simulator, "#simulator-lifecycle")
    assert [_] = Floki.find(simulator, "#add-device")
    directory = Req.get!(client, url: "/devices").body |> Floki.parse_document!()

    assert [_] =
             Floki.find(
               directory,
               "#device-directory tr[data-device-kind=simulated] a[href='/devices/#{vm.id}']"
             )

    assert [] = Floki.find(overview, "#internet-editor")
    assert Req.get!(client, url: "/network").status == 404

    device = Req.get!(client, url: "/devices/#{vm.id}").body |> Floki.parse_document!()
    assert [_] = Floki.find(device, "#device-summary")
    assert [] = Floki.find(device, "#test-results")
    tests = Req.get!(client, url: "/devices/#{vm.id}?tab=tests").body |> Floki.parse_document!()
    assert [_] = Floki.find(tests, "#test-results")

    assert Floki.attribute(device, "#device-ui-link", "href") ==
             [Qemu.ui_url(vm)]

    assert Floki.text(device) =~ "mix dev.ui #{vm.id}"
  end

  defp assert_assets(client) do
    page = Req.get!(client, url: "/")
    assert page.status == 200
    assert page.body =~ ~s(href="/assets/css/app.css")
    assert page.body =~ ~s(src="/assets/js/app.js")

    css = Req.get!(client, url: "/assets/css/app.css")
    assert css.status == 200

    assert Enum.any?(
             Req.Response.get_header(css, "content-type"),
             &String.starts_with?(&1, "text/css")
           )

    assert css.body =~ ".ui-header"
    refute css.body =~ ~s(@import "tailwindcss")

    js = Req.get!(client, url: "/assets/js/app.js")
    assert js.status == 200

    assert Enum.any?(
             Req.Response.get_header(js, "content-type"),
             &String.contains?(&1, "javascript")
           )

    assert js.body =~ "ScrollToBottom"
    refute js.body =~ "/vendor/"
  end
end

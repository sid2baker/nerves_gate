defmodule NervesGate.Scenarios.FrontendAssets do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.TestQemu, as: Qemu
  alias NervesGateWeb.Endpoint
  alias Phoenix.Socket.Transport

  @guest :"nerves_gate@192.168.77.2"

  def name, do: "Host and firmware serve the frontend; firmware needs no Volt runtime"

  def run(vm) do
    assert_websocket_csrf()
    assert Qemu.status(vm).system.node == @guest

    host =
      Req.new(
        base_url: "http://localhost",
        unix_socket: System.fetch_env!("QEMU_HTTP_SOCKET"),
        retry: false
      )

    firmware = Req.new(base_url: "http://192.168.77.2:4000", retry: false)
    assert_assets(host)
    assert_assets(firmware)

    page = Req.get!(firmware, url: "/")
    [csp] = Req.Response.get_header(page, "content-security-policy")
    assert csp =~ "style-src 'self';"
    refute csp =~ "unsafe-inline"
    refute page.body =~ "/@volt/"
    assert Req.get!(firmware, url: "/@volt/client.js").status == 404
    assert :erpc.call(@guest, :code, :where_is_file, [~c"volt.app"]) == :non_existing

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

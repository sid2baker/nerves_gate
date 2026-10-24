defmodule NervesGateWeb.GatewaySocketTest do
  use ExUnit.Case, async: false
  alias NervesGateWeb.Endpoint
  alias Phoenix.Socket.Transport

  setup do
    # Exercise the real transport without a listener or device services. The
    # workbench no longer starts the gateway endpoint just for this assertion.
    previous = Application.get_env(:nerves_gate, Endpoint)

    Application.put_env(:nerves_gate, Endpoint,
      server: false,
      secret_key_base: Base.encode64(:crypto.strong_rand_bytes(64)),
      live_view: [signing_salt: "gateway-socket-test"]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:nerves_gate, Endpoint, previous),
        else: Application.delete_env(:nerves_gate, Endpoint)
    end)

    start_supervised!(Endpoint)
    :ok
  end

  test "gateway WebSockets accept variable origins only with a session-bound CSRF token" do
    assert [{"/live", Phoenix.LiveView.Socket, socket_opts}] = Endpoint.__sockets__()

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
end

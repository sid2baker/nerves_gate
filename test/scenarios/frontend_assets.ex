defmodule NervesGate.Scenarios.FrontendAssets do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.TestQemu, as: Qemu

  @guest :"nerves_gate@192.168.77.2"

  def name, do: "Host and firmware serve the frontend; firmware needs no Volt runtime"

  def run(vm) do
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

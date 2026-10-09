defmodule NervesGateWeb.LiveTest do
  use ExUnit.Case, async: true
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint NervesGateWeb.Endpoint

  test "dashboard and setup work without internet" do
    {:ok, view, html} = live(build_conn(), "/")
    assert html =~ "Your local network"
    assert has_element?(view, "a[href='/setup']")
    {:ok, _view, html} = live(build_conn(), "/setup")
    assert html =~ "Welcome to Nerves Gate"
  end

  test "assets are served locally" do
    for path <- [
          "/assets/app.css",
          "/assets/app.js",
          "/vendor/phoenix/phoenix.mjs",
          "/vendor/live_view/phoenix_live_view.esm.js"
        ] do
      assert build_conn() |> get(path) |> response(200) != ""
    end
  end
end

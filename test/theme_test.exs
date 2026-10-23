defmodule NervesGateWeb.ThemeTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]

  test "the root loads external JavaScript only, compatible with the firmware CSP" do
    document =
      render_component(&NervesGateWeb.Layouts.root/1,
        inner_content: Phoenix.HTML.raw("<main>Gateway</main>")
      )
      |> Floki.parse_document!()

    assert Floki.find(document, "script:not([src])") == []
    assert Floki.attribute(document, "script", "src") == ["/assets/js/app.js"]
  end

  test "theme choices sit behind one icon and need no LiveView click handler" do
    document =
      render_component(&NervesGateWeb.CoreComponents.theme_toggle/1, [])
      |> Floki.parse_document!()

    assert [_] = Floki.find(document, "details:not([open]) > summary[aria-label='Color theme']")
    assert [_] = Floki.find(document, "summary svg")
    assert Floki.text(Floki.find(document, "summary")) |> String.trim() == ""

    assert Floki.attribute(document, "button", "data-theme-choice") == [
             "system",
             "light",
             "dark"
           ]

    assert Floki.find(document, "[phx-click]") == []
    assert Floki.find(document, ".ui-segmented") == []
  end
end

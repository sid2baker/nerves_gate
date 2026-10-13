defmodule NervesGateWeb.DistributionPanelTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias NervesGateWeb.DistributionPanel

  test "shows the actual node and cookie with attached runtime instructions" do
    html =
      render_component(&DistributionPanel.connection/1,
        node: :"nerves_gate@100.88.166.70",
        cookie: :"shared<group>",
        elixir: "1.20.4",
        otp: "29"
      )

    assert html =~ ~s(id="distribution-node">nerves_gate@100.88.166.70</code>)
    assert html =~ ~s(id="distribution-cookie">shared&lt;group&gt;</code>)
    assert html =~ "execute code on the gateway"
    assert html =~ "Attached node"
    assert html =~ "4369"
    assert html =~ "9100"
    assert html =~ "Elixir 1.20.4"
    assert html =~ "OTP 29"
    refute html =~ "distribution-disabled"
  end

  test "does not expose a cookie or pretend distribution is enabled on a non-distributed VM" do
    html =
      render_component(&DistributionPanel.connection/1,
        node: :nonode@nohost,
        cookie: :unused_cookie,
        elixir: "1.20.4",
        otp: "29"
      )

    assert html =~ "distribution-disabled"
    assert html =~ "automatically when Tailscale is online"
    refute html =~ "distribution-cookie"
    refute html =~ "unused_cookie"
  end
end

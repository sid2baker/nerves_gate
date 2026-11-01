defmodule IotrouterExpansion.UITest do
  use ExUnit.Case, async: false
  import Phoenix.LiveViewTest

  test "startup does not discover or touch equipment and explains reset/output effects" do
    html = render_component(IotrouterExpansion.UI, id: "expansion")
    assert html =~ "No expansion bus on this target"
    assert html =~ "outputs return to their power-on state"
    assert html =~ "Nothing starts automatically"
    assert html =~ "disabled"
    assert Process.whereis(IotrouterExpansion.Bus) == nil
  end

  test "assignment is reviewed by the gateway, not granted by a candidate" do
    port = %NervesGateSDK.Hardware.Candidate{
      id: "ttyS5",
      label: "Expansion Bus",
      kind: :iotrouter_expansion,
      present?: true,
      enabled?: false
    }

    html = render_component(IotrouterExpansion.UI, id: "expansion", ports: [port])
    assert html =~ "/hardware/ttyS5?plugin=iotrouter_expansion"
    assert html =~ "Review assignment"
    assert html =~ "Available for assignment"
    assert Process.whereis(IotrouterExpansion.Bus) == nil
  end
end

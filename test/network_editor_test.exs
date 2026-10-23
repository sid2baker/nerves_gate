defmodule Dev.NetworkEditorTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest, only: [render_component: 2]
  alias NervesGateWeb.{NetworkEditor, NetworkForm}

  @base %{"mode" => "ports", "eth0" => nil, "eth1" => nil}

  test "4G choices are visible but disabled when the profile exists without hardware" do
    document = page(@base, false)
    assert Floki.find(document, "input[value=cellular][disabled]") != []
    assert Floki.find(document, "input[value=backup][disabled]") != []
    assert Floki.find(document, "input[value=ethernet]:not([disabled])") != []
    assert Floki.find(document, "#apply-settings[disabled]") == []
    assert Floki.text(document) =~ "No 4G modem detected"
  end

  test "unsupported and unknown hardware cannot enable cellular options" do
    for {present, supported} <- [{nil, true}, {false, false}, {true, false}] do
      document = page(@base, present, supported)
      assert Floki.find(document, "input[value=cellular][disabled]") != []
      assert Floki.find(document, "input[value=backup][disabled]") != []
    end

    assert Floki.text(page(@base, false, false)) =~ "4G is not supported"
  end

  test "a detected modem enables 4G before registration or SIM unlock" do
    document = page(@base, true)
    assert Floki.find(document, "input[value=cellular]:not([disabled])") != []
    assert Floki.find(document, "input[value=backup]:not([disabled])") != []
  end

  test "network-default APN needs no entry and manual override is collapsed under Advanced" do
    document = page(cellular(""), true)
    assert Floki.text(document) =~ "mobile network's default APN"
    assert Floki.find(document, "details#cellular-advanced:not([open])") != []
    assert Floki.find(document, "#cellular-advanced input[name='network[cellular_apn]']") != []

    assert Floki.attribute(document, "input[name='network[cellular_apn]']", "placeholder") == [
             "Network default"
           ]

    assert Floki.find(document, "input[name='network[cellular_apn]'][required]") == []
    assert Floki.text(document) =~ "enter it there to unlock and remember it"
    refute Floki.text(document) =~ "direct USB"
    refute Floki.text(document) =~ "SIM must already be unlocked"
    refute Floki.text(document) =~ "PIN and account-password setup are not supported yet"
  end

  test "an existing manual APN remains visible and unchanged" do
    document = page(cellular("private.example"), true)
    assert Floki.find(document, "details#cellular-advanced[open]") != []

    assert Floki.attribute(document, "input[name='network[cellular_apn]']", "value") == [
             "private.example"
           ]
  end

  test "a missing modem disables a saved cellular draft without silently replacing it" do
    document = page(cellular("private.example"), false)
    assert Floki.find(document, "input[value=cellular][checked][disabled]") != []
    assert Floki.find(document, "input[name='network[cellular_apn]'][disabled]") != []

    assert Floki.attribute(document, "input[name='network[cellular_apn]']", "value") == [
             "private.example"
           ]

    assert Floki.find(document, "#apply-settings[disabled]") != []
    assert Floki.find(document, "input[value=ethernet]:not([disabled])") != []
  end

  test "blank APN form round-trips as the network default; explicit overrides can be cleared" do
    for apn <- ["", "private.example"] do
      network = cellular(apn)
      params = NetworkForm.from_settings(network, :internet)
      assert params["cellular_apn"] == apn
      assert {:ok, ^network} = NetworkForm.to_network(params, [], network, :internet)
      cleared = Map.put(params, "cellular_apn", "   ")
      assert {:ok, updated} = NetworkForm.to_network(cleared, [], network, :internet)
      assert updated["internet"]["apn"] == ""
    end
  end

  defp cellular(apn), do: Map.put(@base, "internet", %{"mode" => "cellular", "apn" => apn})

  defp page(network, present, supported \\ true) do
    observed = %{
      cellular: if(present != nil, do: %{present: present}),
      ports: [],
      usb: nil
    }

    projection = %{
      network: %{
        desired: network,
        observed: observed,
        available: true,
        setup_completed: true,
        pending: nil,
        error: nil
      },
      connections: %{ports: [], suggested_internet_port: nil},
      capabilities: %{mobile: supported},
      actions: %{"network.propose" => %{enabled: true}}
    }

    render_component(NetworkEditor,
      id: "internet-editor",
      editor: :internet,
      projection: projection,
      access: nil
    )
    |> Floki.parse_document!()
  end
end

defmodule NervesGateWeb.NetworkFormTest do
  use ExUnit.Case, async: true
  alias NervesGateWeb.NetworkForm

  defp fresh, do: NetworkForm.from_settings(NervesGate.Config.defaults()["network"])

  defp port(name, ip, prefix),
    do: %{
      name: name,
      link: true,
      connection: :internet,
      addresses: [%{address: ip, prefix_length: prefix}]
    }

  test "manual defaults use the selected interface lease, prefix, router and DNS" do
    wan =
      port("eth1", "10.8.4.20", 20)
      |> Map.merge(%{gateway: "10.8.0.1", nameservers: ["10.8.0.53"]})

    observed = %{ports: [wan], usb: nil, bridge: nil}

    params =
      fresh()
      |> Map.put("internet_port", "eth1")
      |> NetworkForm.static_defaults("internet", observed)

    assert params["internet_ip"] == "10.8.4.20"
    assert params["internet_mask"] == "255.255.240.0"
    assert params["internet_gateway"] == "10.8.0.1"
    assert params["internet_dns"] == "10.8.0.53"

    assert NetworkForm.static_defaults(
             Map.put(params, "internet_gateway", ""),
             "internet",
             observed
           )["internet_gateway"] == ""
  end

  test "offline defaults are populated and equipment suggestions avoid known WAN and USB subnets" do
    observed = %{ports: [], usb: nil, bridge: nil}
    manual = NetworkForm.static_defaults(fresh(), "internet", observed)
    assert manual["internet_ip"] == "192.168.1.2"
    assert manual["internet_gateway"] == "192.168.1.1"
    assert manual["internet_dns"] == "192.168.1.1"

    observed = %{
      observed
      | ports: [port("eth0", "192.168.10.8", 16)],
        usb: port("usb0", "10.42.0.1", 30)
    }

    params =
      fresh()
      |> Map.put("equipment_port", "eth1")
      |> NetworkForm.static_defaults("equipment", observed)

    assert params["equipment_ip"] == "172.22.0.2"
    assert params["equipment_gateway"] == ""
  end

  test "unsupported learned prefixes use valid manual examples" do
    observed = %{ports: [port("eth0", "10.0.0.1", 32)], usb: nil, bridge: nil}

    params =
      fresh()
      |> Map.put("internet_port", "eth0")
      |> NetworkForm.static_defaults("internet", observed)

    assert params["internet_ip"] == "192.168.1.2"
    assert params["internet_mask"] == "255.255.255.0"
  end

  test "existing manual addresses and edits are never overwritten" do
    params =
      Map.merge(fresh(), %{
        "internet_ip" => "10.90.0.2",
        "internet_mask" => "255.255.0.0",
        "internet_gateway" => ""
      })

    assert NervesGateWeb.NetworkForm.static_defaults(params, "internet", nil) == params
  end
end

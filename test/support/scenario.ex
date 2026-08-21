defmodule NervesGate.TestScenario do
  @moduledoc false
  alias NervesGate.Internet.Config

  def temporary_root(context) do
    root =
      Path.join(
        System.tmp_dir!(),
        "nerves_gate_test_#{context}_#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    root
  end

  def dhcp(interface \\ "eth0") do
    {:ok, config} = Config.new(%{interface: interface, kind: :ethernet, method: :dhcp})
    config
  end

  def static(interface \\ "eth0", gateway \\ "192.0.2.1") do
    {:ok, config} =
      Config.new(%{
        interface: interface,
        kind: :ethernet,
        method: :static,
        address: "192.0.2.20",
        prefix_length: 24,
        gateway: gateway,
        dns_primary: "1.1.1.1",
        dns_secondary: "9.9.9.9",
        search_domain: "field.example"
      })

    config
  end

  def checks(overrides \\ %{}) do
    Map.merge(
      %{
        physical_link: :ok,
        ip_address: :ok,
        default_route: :ok,
        dns: :ok,
        internet_https: :ok,
        tailscale: :unknown
      },
      overrides
    )
  end
end

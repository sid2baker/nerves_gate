defmodule NervesGate.Gateway.SettingsTest do
  use ExUnit.Case, async: true

  alias NervesGate.Gateway.Settings

  test "subnet routes are canonicalized and deduplicated before persistence" do
    assert {:ok, subnet_router} =
             Settings.validate_subnet_router(%{
               "enabled" => true,
               "routes" => [
                 "192.168.10.42/24",
                 "192.168.10.0/24",
                 "2001:db8::42/64"
               ]
             })

    assert subnet_router == %{
             "enabled" => true,
             "routes" => ["192.168.10.0/24", "2001:db8::/64"]
           }
  end

  test "enabled subnet routing requires at least one route" do
    assert {:error, :subnet_routes_required} =
             Settings.require_enabled_routes(%{"enabled" => true, "routes" => []})

    assert :ok = Settings.require_enabled_routes(%{"enabled" => false, "routes" => []})
  end
end

defmodule Scenarios.Cases.HardwareReadiness do
  @moduledoc "Read-only EC100 readiness. This does not exercise failover or change configuration."
  import ExUnit.Assertions

  def spec do
    %{
      name: "Physical network readiness over verified SSH (read-only)",
      requires: %{device: [], fixture: [:ssh_management]},
      opt_in: true
    }
  end

  def run(%{snapshot: snapshot, profile: profile}) do
    assert snapshot["target"] == "ec100", "Expected a physical EC100"
    assert snapshot["available"] == true, "Device status is unavailable"

    assert snapshot["pending"] == false,
           "Finish or restore the active network trial in the gateway first"

    assert snapshot["recovering"] == false,
           "Network recovery is still active; wait for restoration before testing"

    assert snapshot["ready"] == true,
           "Saved network topology is not applied or has address conflicts. Open the gateway's Internet/settings pages and inspect port configuration; this is not an Internet reachability check."

    internet = snapshot["internet"]
    assert internet["health"] == "online", "Internet connectivity has not been confirmed"

    case profile do
      "ethernet" ->
        assert internet["mode"] == "ethernet",
               "Expected Ethernet-only, but the gateway reports #{internet["mode"] || "unknown"}. Select the matching expected profile above, or deliberately change the profile in the gateway first."

        ethernet!(internet)

      "cellular" ->
        assert internet["mode"] == "cellular",
               "Expected 4G-only, but the gateway reports #{internet["mode"] || "unknown"}. Select the matching expected profile above, or deliberately change the profile in the gateway first."

        cellular!(snapshot)
        assert internet["selected"] == "cellular", "4G is not the selected Internet source"

      "backup" ->
        assert internet["mode"] == "backup",
               "Expected Ethernet with 4G backup, but the gateway reports #{internet["mode"] || "unknown"}. Select the matching expected profile above, or deliberately change the profile in the gateway first."

        ethernet!(internet)
        cellular!(snapshot)
        assert internet["cellular"] == "internet", "Backup cellular Internet is not ready"

      _ ->
        flunk("Unknown network readiness profile")
    end
  end

  defp ethernet!(internet) do
    assert internet["ethernet"] == "internet", "Ethernet Internet is not ready"
    assert internet["selected"] == "ethernet", "Ethernet is not the selected Internet source"
  end

  defp cellular!(snapshot) do
    cellular = snapshot["cellular"]
    assert cellular["supported"] == true, "This target does not support cellular Internet"
    assert cellular["present"] == true, "The declared modem is missing"
    assert cellular["enabled"] == true, "Cellular Internet is disabled"

    assert cellular["sim"] == "ready",
           "The SIM is not ready; complete SIM commissioning on the gateway"

    assert snapshot["internet"]["cellular"] == "internet",
           "Cellular Internet has not been confirmed"
  end
end

defmodule Scenarios.Cases.HardwareReadiness do
  @moduledoc "Read-only readiness of a physical gateway for its configured Internet profile."
  import ExUnit.Assertions

  def spec do
    %{
      name: "Physical network readiness for the configured profile (read-only)",
      requires: %{device: [], fixture: [:physical]},
      opt_in: true
    }
  end

  def run(%{device: device}), do: check!(observe(device))

  @doc "Sanitized hardware observation with string keys."
  def observe(device) do
    device
    |> Scenarios.Device.rpc(NervesGate.System, :hardware_info, [], 5_000)
    |> Jason.encode!()
    |> Jason.decode!()
  end

  def check!(snapshot) do
    assert snapshot["available"] == true, "Device status is unavailable"
    assert snapshot["pending"] == false, "Finish or restore the active network trial first"
    assert snapshot["recovering"] == false, "Network recovery is still active"

    assert snapshot["ready"] == true,
           "Saved network topology is not applied or has address conflicts; inspect the gateway's Internet settings"

    internet = snapshot["internet"]
    assert internet["health"] == "online", "Internet connectivity has not been confirmed"

    case internet["mode"] do
      "ethernet" ->
        ethernet!(internet)

      "cellular" ->
        cellular!(snapshot)
        assert internet["selected"] == "cellular", "4G is not the selected Internet source"

      "backup" ->
        ethernet!(internet)
        cellular!(snapshot)

      mode ->
        flunk("Unknown Internet profile #{inspect(mode)}")
    end

    snapshot
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
    assert cellular["sim"] == "ready", "The SIM is not ready; complete SIM commissioning"

    assert snapshot["internet"]["cellular"] == "internet",
           "Cellular Internet has not been confirmed"
  end
end

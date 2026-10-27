defmodule Scenarios.Cases.HardwareBackup do
  @moduledoc "Operator-assisted Ethernet loss → 4G takeover → Ethernet return on a physical gateway."
  import ExUnit.Assertions
  alias Scenarios.Cases.HardwareReadiness

  def spec do
    %{
      name: "Ethernet / 4G takeover and return (operator unplugs cables; uses cellular data)",
      requires: %{device: [], fixture: [:physical]},
      opt_in: true
    }
  end

  def run(%{device: device}) do
    report = Process.get(:scenario_report, fn _ -> :ok end)
    before = HardwareReadiness.check!(HardwareReadiness.observe(device))
    assert before["internet"]["mode"] == "backup", "Configure Ethernet with 4G backup first"

    assert before["internet"]["ethernet_link"] == true,
           "A linked Ethernet Internet port must be observed before disconnecting a cable"

    report.(
      "Disconnect the Ethernet Internet uplink cables now (never power). Waiting two minutes for link loss and online 4G."
    )

    wait_for!(device, before, :takeover, deadline())
    report.("4G takeover observed. Restore every Ethernet cable now. Waiting two minutes.")
    wait_for!(device, before, :return, deadline())
    report.("Ethernet link and preference restored; 4G remains ready.")
  end

  @doc false
  def phase?(:takeover, snapshot) do
    internet = snapshot["internet"] || %{}

    internet["ethernet_link"] == false and internet["selected"] == "cellular" and
      internet["cellular"] == "internet" and internet["health"] == "online"
  end

  def phase?(:return, snapshot) do
    internet = snapshot["internet"] || %{}

    internet["ethernet_link"] == true and internet["selected"] == "ethernet" and
      internet["ethernet"] == "internet" and internet["cellular"] == "internet" and
      internet["health"] == "online"
  end

  defp wait_for!(device, before, phase, until) do
    assert System.monotonic_time(:millisecond) < until,
           "Timed out waiting for #{phase}. Restore Ethernet cables; nothing was changed or retried."

    snapshot = HardwareReadiness.observe(device)

    assert Map.take(snapshot, ~w(serial boot_id version)) ==
             Map.take(before, ~w(serial boot_id version)),
           "Gateway rebooted or changed during the test. Restore Ethernet and inspect it."

    assert snapshot["pending"] == false and snapshot["recovering"] == false and
             snapshot["internet"]["mode"] == "backup",
           "Network configuration changed during the test. Restore Ethernet and inspect the gateway."

    unless phase?(phase, snapshot) do
      Process.sleep(1_000)
      wait_for!(device, before, phase, until)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 120_000
end

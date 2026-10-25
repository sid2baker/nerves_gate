defmodule Scenarios.Cases.HardwareBackup do
  @moduledoc "Operator-assisted cable-loss and failback, observed over independent USB management."
  import ExUnit.Assertions

  def spec do
    %{
      name: "USB-observed Ethernet / 4G takeover and return (operator-assisted)",
      requires: %{device: [], fixture: [:usb_management, :manual_ethernet]},
      opt_in: true
    }
  end

  def run(context) do
    Scenarios.Cases.HardwareReadiness.run(%{snapshot: context.snapshot, profile: "backup"})

    assert context.snapshot["internet"]["ethernet_link"] == true,
           "A linked Ethernet Internet port must be observed before disconnecting a cable"

    context.report.(
      "Disconnect Ethernet Internet uplink cables now, never USB or power. Waiting up to two minutes for physical link loss and online 4G takeover. Cellular data may be used."
    )

    wait_for!(context, :takeover, deadline())

    context.report.(
      "4G takeover observed with Ethernet link down. Restore every Ethernet cable now. Waiting up to two minutes for Ethernet preference and online connectivity."
    )

    wait_for!(context, :return, deadline())

    context.report.(
      "Ethernet link and preference restored; 4G remains ready. USB management and device boot were unchanged."
    )
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

  defp wait_for!(context, phase, until) do
    assert System.monotonic_time(:millisecond) < until,
           "Timed out waiting for #{phase}. Restore Ethernet cables; no configuration was changed or recovery action retried."

    snapshot = context.read_snapshot.()

    assert snapshot["ready"] == true and snapshot["pending"] == false and
             snapshot["recovering"] == false and snapshot["internet"]["mode"] == "backup",
           "Network configuration/trial changed during the test. Restore Ethernet and inspect the gateway."

    if phase?(phase, snapshot) do
      :ok
    else
      Process.sleep(1_000)
      wait_for!(context, phase, until)
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 120_000
end

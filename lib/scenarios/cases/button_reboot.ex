defmodule Scenarios.Cases.ButtonReboot do
  @moduledoc "Operator presses the physical reboot button; observe a healthy new boot of the same gateway."
  import ExUnit.Assertions
  alias Scenarios.Cases.HardwareReadiness

  def spec do
    %{
      name: "Physical-button reboot returns healthy (operator presses the button)",
      requires: %{device: [], fixture: [:physical]},
      opt_in: true
    }
  end

  def run(%{device: device}) do
    report = Process.get(:scenario_report, fn _ -> :ok end)
    before = HardwareReadiness.observe(device)
    assert before["firmware_validated"] == true, "Wait for validated firmware first"

    report.(
      "Short-press and release once to arm, then hold 5–10 seconds and release while RUN blinks slowly. Never hold 30 seconds (factory reset). Waiting three minutes; the workbench sends no reboot command."
    )

    await(device, before, System.monotonic_time(:millisecond) + 180_000)
  end

  defp await(device, before, until) do
    assert System.monotonic_time(:millisecond) < until,
           "No healthy new boot observed. Inspect the gateway; do not repeat the button action automatically."

    observed =
      try do
        device.node
        |> :erpc.call(NervesGate.System, :hardware_info, [], 2_000)
        |> Jason.encode!()
        |> Jason.decode!()
      catch
        _, _ -> nil
      end

    cond do
      observed && Map.take(observed, ~w(serial version)) != Map.take(before, ~w(serial version)) ->
        flunk("Gateway identity or firmware changed while observing the reboot")

      observed && observed["boot_id"] != before["boot_id"] && observed["available"] &&
          observed["firmware_validated"] ->
        :ok

      true ->
        Process.sleep(1_000)
        await(device, before, until)
    end
  end
end

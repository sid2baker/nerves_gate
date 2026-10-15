defmodule NervesGate.ManualFaults do
  @moduledoc "Reversible bench controls. One long-lived worker owns all cleanup callbacks."
  alias NervesGate.TestQemu, as: Qemu

  def controls do
    [
      %{
        id: "connection",
        name: "Internet cable",
        choices: [
          {"connect_lan1", "LAN1"},
          {"connect_lan2", "LAN2"},
          {"connect_off", "Off"}
        ]
      },
      %{
        id: "lan1",
        name: "LAN1 · eth0",
        choices: [{"lan1_down", "Disconnect"}, {"lan1_up", "Reconnect"}]
      },
      %{
        id: "lan2",
        name: "LAN2 · eth1",
        choices: [{"lan2_down", "Disconnect"}, {"lan2_up", "Reconnect"}]
      },
      %{
        id: "internet",
        name: "Internet uplink",
        choices: [
          {"internet_down", "Outage"},
          {"internet_loss", "50% loss"},
          {"internet_up", "Restore"}
        ]
      },
      %{
        id: "latency",
        name: "Uplink latency",
        choices: [{"latency_on", "+200 ms"}, {"latency_off", "Remove delay"}]
      },
      %{id: "vm", name: "Virtual machine", choices: [{"pause", "Pause"}, {"resume", "Resume"}]}
    ]
  end

  def actions,
    do: ["clear", "release" | for(control <- controls(), {id, _} <- control.choices, do: id)]

  def execute(owner, vm) do
    Qemu.adopt(vm)

    try do
      Qemu.start_internet_faults(vm)
      send(owner, {:manual_ready, self()})
      loop(owner, vm, initial())
    after
      Qemu.cleanup()
    end

    send(owner, {:manual_released, self()})
  end

  defp initial, do: %{delayed: false}

  defp loop(owner, vm, state) do
    receive do
      {:manual_action, "release"} ->
        :ok

      {:manual_action, action} ->
        state = apply_action(vm, action, state)
        send(owner, {:manual_done, self(), action})
        loop(owner, vm, state)
    end
  end

  defp apply_action(vm, "connect_" <> destination, state) do
    port = Map.fetch!(%{"lan1" => :lan1, "lan2" => :lan2, "off" => :off}, destination)
    Qemu.connect_internet(vm, port)
    state
  end

  defp apply_action(vm, "latency_on", state) do
    Qemu.delay_internet(vm)
    %{state | delayed: true}
  end

  defp apply_action(vm, "latency_off", state) do
    if state.delayed, do: Qemu.clear_delay(vm)
    %{state | delayed: false}
  end

  defp apply_action(vm, "clear", state) do
    Qemu.resume(vm)
    Qemu.restore_connections(vm)
    Qemu.restore_internet(vm)
    if state.delayed, do: Qemu.clear_delay(vm)
    initial()
  end

  defp apply_action(vm, action, state)
       when action in ["internet_down", "internet_loss", "internet_up"] do
    Qemu.restore_internet(vm)

    case action do
      "internet_down" -> Qemu.drop_internet(vm)
      "internet_loss" -> Qemu.lose_internet_packets(vm)
      "internet_up" -> :ok
    end

    state
  end

  defp apply_action(vm, "pause", state) do
    Qemu.pause(vm)
    state
  end

  defp apply_action(vm, "resume", state) do
    Qemu.resume(vm)
    state
  end

  defp apply_action(vm, action, state) do
    {port, up} =
      case action do
        "lan1_" <> direction -> {:lan1, direction == "up"}
        "lan2_" <> direction -> {:lan2, direction == "up"}
      end

    Qemu.set_cable(vm, port, up)
    state
  end
end

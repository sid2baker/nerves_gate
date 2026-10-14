defmodule NervesGate.ManualFaults do
  @moduledoc "Reversible bench controls. One long-lived worker owns all cleanup callbacks."
  alias NervesGate.TestQemu, as: Qemu

  def controls do
    [
      %{
        id: "wan",
        name: "WAN Ethernet · eth0",
        choices: [{"wan_down", "Disconnect"}, {"wan_up", "Reconnect"}]
      },
      %{
        id: "equipment",
        name: "Equipment Ethernet · eth1",
        choices: [{"equipment_down", "Disconnect"}, {"equipment_up", "Reconnect"}]
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
    try do
      Qemu.start_internet_faults(vm)
      send(owner, {:manual_ready, self()})
      loop(owner, vm, false)
    after
      Qemu.cleanup()
    end

    send(owner, {:manual_released, self()})
  end

  defp loop(owner, vm, delayed) do
    receive do
      {:manual_action, "release"} ->
        :ok

      {:manual_action, action} ->
        delayed = apply_action(vm, action, delayed)
        send(owner, {:manual_done, self(), action})
        loop(owner, vm, delayed)
    end
  end

  defp apply_action(vm, "latency_on", _) do
    Qemu.delay_internet(vm)
    true
  end

  defp apply_action(vm, "latency_off", delayed) do
    if delayed, do: Qemu.clear_delay(vm)
    false
  end

  defp apply_action(vm, "clear", delayed) do
    Qemu.resume(vm)
    Qemu.reconnect_wan(vm)
    Qemu.reconnect_equipment(vm)
    Qemu.restore_internet(vm)
    if delayed, do: Qemu.clear_delay(vm)
    false
  end

  defp apply_action(vm, action, delayed)
       when action in ["internet_down", "internet_loss", "internet_up"] do
    Qemu.restore_internet(vm)

    case action do
      "internet_down" -> Qemu.drop_internet(vm)
      "internet_loss" -> Qemu.lose_internet_packets(vm)
      "internet_up" -> :ok
    end

    delayed
  end

  defp apply_action(vm, action, delayed) do
    case action do
      "wan_down" ->
        Qemu.disconnect_wan(vm)

      "wan_up" ->
        Qemu.reconnect_wan(vm)

      "equipment_down" ->
        Qemu.disconnect_equipment(vm)

      "equipment_up" ->
        Qemu.reconnect_equipment(vm)

      "pause" ->
        Qemu.pause(vm)

      "resume" ->
        Qemu.resume(vm)
    end

    delayed
  end
end

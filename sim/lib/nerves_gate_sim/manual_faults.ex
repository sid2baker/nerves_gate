defmodule NervesGateSim.ManualFaults do
  @moduledoc "Reversible bench controls. One long-lived worker owns cleanup."
  alias NervesGateSim.Simulator.Network
  alias NervesGateSim.TestQemu

  @controls [
    {"connection", "Internet cable",
     [
       {"connect_lan1", "LAN1", %{internet: :lan1}},
       {"connect_lan2", "LAN2", %{internet: :lan2}},
       {"connect_off", "Off", %{internet: :off}}
     ]},
    {"lan1", "LAN1 · eth0",
     [
       {"lan1_down", "Disconnect", %{cables: %{lan1: false}}},
       {"lan1_up", "Reconnect", %{cables: %{lan1: true}}}
     ]},
    {"lan2", "LAN2 · eth1",
     [
       {"lan2_down", "Disconnect", %{cables: %{lan2: false}}},
       {"lan2_up", "Reconnect", %{cables: %{lan2: true}}}
     ]},
    {"internet", "Internet uplink",
     [
       {"internet_down", "Outage", %{uplink: %{loss: :all}}},
       {"internet_loss", "50% loss", %{uplink: %{loss: :alternate}}},
       {"internet_up", "Restore", %{uplink: %{loss: :none}}}
     ]},
    {"latency", "Uplink latency",
     [
       {"latency_on", "+200 ms", %{uplink: %{delay_ms: 200}}},
       {"latency_off", "Remove delay", %{uplink: %{delay_ms: 0}}}
     ]},
    {"vm", "Virtual machine", [{"pause", "Pause", :pause}, {"resume", "Resume", :resume}]}
  ]
  @actions Map.new(
             for {_, _, choices} <- @controls, {id, _, command} <- choices, do: {id, command}
           )

  def controls do
    for {id, name, choices} <- @controls do
      %{id: id, name: name, choices: for({key, label, _} <- choices, do: {key, label})}
    end
  end

  def actions, do: ["clear", "release" | Map.keys(@actions)]

  def execute(owner, vm) do
    try do
      :ok = TestQemu.network(vm, %{})
      send(owner, {:manual_ready, self()})
      loop(owner, vm)
    after
      TestQemu.cleanup()
    end

    send(owner, {:manual_released, self()})
  end

  defp loop(owner, vm) do
    receive do
      {:manual_action, "release"} ->
        :ok

      {:manual_action, action} ->
        apply_action(vm, action)
        send(owner, {:manual_done, self(), action})
        loop(owner, vm)
    end
  end

  defp apply_action(vm, "clear") do
    TestQemu.resume(vm)
    :ok = TestQemu.network(vm, Network.defaults())
  end

  defp apply_action(vm, action) do
    case Map.fetch!(@actions, action) do
      :pause -> TestQemu.pause(vm)
      :resume -> TestQemu.resume(vm)
      patch -> :ok = TestQemu.network(vm, patch)
    end
  end
end

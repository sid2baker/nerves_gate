defmodule NervesGate.DeviceState.HealingTest do
  use ExUnit.Case, async: false

  alias NervesGate.DeviceState.Server
  alias NervesGate.Internet.Config
  alias NervesGate.TestScenario

  test "runtime healing reapplies only accepted settings through the authoritative server" do
    owner = self()
    original = :sys.get_state(Server)

    current =
      original.current
      |> Map.put("configured", true)
      |> Map.put("internet", TestScenario.dhcp() |> Config.to_persisted())
      |> Map.put("cluster", %{"group" => "healing-group"})
      |> Map.put("ssh_enabled", true)
      |> Map.put("subnet_router", %{
        "enabled" => true,
        "routes" => ["192.168.50.0/24"]
      })

    ops =
      original.ops
      |> Map.put(:internet_restore, fn config ->
        send(owner, {:internet_restore, config})
        :ok
      end)
      |> Map.put(:internet_observe, fn ->
        send(owner, :internet_observe)
        :ok
      end)
      |> Map.put(:cluster, fn group ->
        send(owner, {:cluster, group})
        :ok
      end)
      |> Map.put(:ssh, fn enabled ->
        send(owner, {:ssh, enabled})
        :ok
      end)
      |> Map.put(:subnet_router, fn enabled, routes ->
        send(owner, {:subnet_router, enabled, routes})
        {:ok, routes}
      end)

    :sys.replace_state(Server, &%{&1 | current: current, pending: nil, ops: ops})

    try do
      assert :ok = Server.heal(:internet)
      assert_receive {:internet_restore, %Config{interface: "eth0"}}
      assert_receive :internet_observe

      assert :ok = Server.heal(:cluster)
      assert_receive {:cluster, "healing-group"}

      assert :ok = Server.heal(:ssh)
      assert_receive {:ssh, true}

      assert :ok = Server.heal(:subnet_router)
      assert_receive {:subnet_router, true, ["192.168.50.0/24"]}

      assert :sys.get_state(Server).current == current
    after
      :sys.replace_state(Server, fn _state -> original end)
    end
  end

  test "healing is rejected before configuration and during every candidate" do
    original = :sys.get_state(Server)

    try do
      :sys.replace_state(Server, fn state ->
        %{state | current: Map.put(state.current, "configured", false), pending: nil}
      end)

      assert {:error, :not_configured} = Server.heal(:internet)

      :sys.replace_state(Server, fn state -> %{state | pending: %{id: "candidate"}} end)

      assert {:error, :configuration_change_in_progress} = Server.heal(:internet)
      assert {:error, :configuration_change_in_progress} = Server.heal(:cluster)
      assert {:error, :configuration_change_in_progress} = Server.heal(:ssh)
      assert {:error, :configuration_change_in_progress} = Server.heal(:subnet_router)
    after
      :sys.replace_state(Server, fn _state -> original end)
    end
  end
end

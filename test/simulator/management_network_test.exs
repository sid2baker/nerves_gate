defmodule Workbench.ManagementNetworkTest do
  use ExUnit.Case, async: true
  alias Workbench.ManagementNetwork

  setup do
    requested = plan()

    created =
      requested
      |> names()
      |> Enum.with_index(10)
      |> Enum.map(fn {name, index} -> %{name: name, index: to_string(index)} end)

    %{requested: requested, recorded: Map.merge(requested, %{ready: true, created: created})}
  end

  test "fresh setup records no ownership before creating interfaces", %{requested: requested} do
    assert ManagementNetwork.setup_plan!(requested, nil, ["lo", "eth0"]) ==
             Map.put(requested, :created, [])

    for name <- names(requested) do
      assert_raise RuntimeError, ~r/interfaces still exist/, fn ->
        ManagementNetwork.setup_plan!(requested, nil, [name])
      end
    end
  end

  test "absent recorded network keeps names and settings but forgets old kernel identities", %{
    recorded: recorded
  } do
    # A newly computed request has different generated interface names. Recovery
    # must retain the recorded names and mapping, not allocate a second network.
    requested = plan([:gateway_b, :gateway_a])
    restored = ManagementNetwork.setup_plan!(requested, recorded, ["lo", "unrelated-bridge"])
    assert restored == %{recorded | ready: false, created: []}
    assert restored.bridge == recorded.bridge
    assert restored.devices == recorded.devices
  end

  test "any surviving or name-conflicting interface refuses recovery", %{
    requested: requested,
    recorded: recorded
  } do
    [bridge, tap1, tap2] = names(recorded)

    # Even if a surviving interface has the original index, setup cannot adopt
    # it. Names alone prove that the all-absent recovery condition is not met.
    for present <- [
          [bridge],
          [tap1],
          [tap2],
          [bridge, tap1],
          [bridge, tap2],
          [tap1, tap2],
          [bridge, tap1, tap2]
        ] do
      assert_raise RuntimeError, ~r/interfaces still exist/, fn ->
        ManagementNetwork.setup_plan!(requested, recorded, present)
      end
    end
  end

  test "recovery cannot change subnet, device set, addresses, MACs or owner", %{
    requested: requested,
    recorded: recorded
  } do
    for changed <- [
          plan([:gateway_a]),
          plan([:gateway_a, :gateway_b, :gateway_c]),
          plan([:gateway_a, :gateway_c]),
          plan([:gateway_a, :gateway_b], "10.203.43.0/24"),
          %{requested | uid: "other-user"},
          %{requested | host: "10.203.42.100"},
          put_in(requested.devices.gateway_a.address, "10.203.42.100"),
          put_in(requested.devices.gateway_a.mac, "52:54:00:00:00:ff")
        ] do
      assert_raise RuntimeError, ~r/settings differ/, fn ->
        ManagementNetwork.setup_plan!(changed, recorded, [])
      end
    end
  end

  test "incomplete ownership journals still need explicit cleanup", %{
    requested: requested,
    recorded: recorded
  } do
    for incomplete <- [
          %{recorded | ready: false},
          %{recorded | created: []},
          %{recorded | created: tl(recorded.created)},
          %{recorded | created: recorded.created ++ [%{name: "unexpected", index: "99"}]}
        ] do
      assert_raise RuntimeError, ~r/setup is incomplete/, fn ->
        ManagementNetwork.setup_plan!(requested, incomplete, [])
      end
    end
  end

  test "planning still rejects host or VPN overlap before recovery can change the journal" do
    for destination <- ["10.203.42.0/24", "10.203.0.0/16", "10.203.42.9/32"] do
      assert_raise RuntimeError, ~r/overlaps host route/, fn ->
        ManagementNetwork.plan!("10.203.42.0/24", [:gateway_a], [%{"dst" => destination}])
      end
    end
  end

  defp plan(ids \\ [:gateway_a, :gateway_b], subnet \\ "10.203.42.0/24"),
    do: ManagementNetwork.plan!(subnet, ids, []) |> Map.put(:uid, "1000")

  defp names(network),
    do: [network.bridge | Enum.map(Enum.sort(network.devices), fn {_, port} -> port.tap end)]
end

defmodule NervesGate.DeviceState.DataTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.Data

  test "singular mode starts disabled rather than unhealthy" do
    assert data().cluster.status == :disabled
  end

  test "the same operation stream produces identical data in every process" do
    operations = [
      {:set_internet, :internet, %{status: :online, reason: nil}},
      {:set_tailnet, :tailnet,
       %{
         observed_status: :online,
         authenticated: true,
         hostname: "gate-a",
         ipv4: "100.64.0.10"
       }},
      {:configure_subnet_router, :subnet_router, %{enabled: true, routes: ["192.168.10.0/24"]}},
      {:observe_subnet_router, :subnet_router,
       %{
         advertised: ["192.168.10.0/24"],
         approved: ["192.168.10.0/24"],
         primary: ["192.168.10.0/24"],
         error: nil
       }},
      {:configure_ssh, :ssh, %{enabled: true}},
      {:observe_ssh, :ssh,
       %{enabled: true, state: :listening, address: {100, 64, 0, 10}, port: 22}},
      {:set_cluster, :cluster,
       %{
         runtime_status: :online,
         enabled: true,
         group: "Plant_floor",
         node: "nervesgate@100.64.0.10",
         connected: []
       }},
      {:set_name, :device, "Boiler room"},
      {:set_alarm, :alarms,
       %{id: "Internet.Alarm", description: "Internet unavailable", level: :warning}}
    ]

    owner = Enum.reduce(operations, data(), &apply!(&2, &1))
    client = Enum.reduce(operations, data(), &apply!(&2, &1))

    assert owner == client
    assert owner.name == "Boiler room"
    assert owner.internet.status == :online
    assert owner.tailnet.status == :online
    assert owner.subnet_router.status == :online
    assert owner.ssh.state == :listening
    assert owner.cluster.status == :online
  end

  test "downstream layers become blocked without losing observed state" do
    data =
      data()
      |> apply!({:set_internet, :internet, %{status: :online, reason: nil}})
      |> apply!(
        {:set_tailnet, :tailnet,
         %{
           observed_status: :online,
           authenticated: true,
           hostname: "gate-a",
           ipv4: "100.64.0.10"
         }}
      )
      |> apply!(
        {:configure_subnet_router, :subnet_router, %{enabled: true, routes: ["192.168.10.0/24"]}}
      )
      |> apply!(
        {:observe_subnet_router, :subnet_router,
         %{advertised: ["192.168.10.0/24"], approved: [], primary: [], error: nil}}
      )
      |> apply!(
        {:set_cluster, :cluster,
         %{
           runtime_status: :online,
           enabled: true,
           group: "Plant_floor",
           node: "nervesgate@100.64.0.10",
           connected: []
         }}
      )
      |> apply!({:set_internet, :internet, %{status: :failed, reason: :no_carrier}})

    assert data.internet.status == :failed
    assert data.tailnet.status == :blocked
    assert data.tailnet.observed_status == :online
    assert data.subnet_router.status == :blocked
    assert data.cluster.status == :blocked

    recovered = apply!(data, {:set_internet, :internet, %{status: :online, reason: nil}})
    assert recovered.tailnet.status == :online
    assert recovered.subnet_router.status == :online
    assert recovered.cluster.status == :online
  end

  test "alarm and connectivity operations accept only canonical public fields" do
    alarm = %{id: "Cluster.Alarm", description: "Cluster unavailable", level: :warning}
    data = apply!(data(), {:set_alarm, :alarms, alarm})

    assert data.alarms == [alarm]
    assert apply!(data, {:set_alarm, :alarms, alarm}) == data
    assert apply!(data, {:clear_alarm, :alarms, alarm.id}).alarms == []

    operation =
      {:set_cluster, :cluster,
       %{
         enabled: true,
         runtime_status: :online,
         connected: [],
         credential: "must-not-replicate"
       }}

    assert :error = Data.apply_operation(data, operation)
    refute inspect(data) =~ "must-not-replicate"

    public =
      apply!(
        data,
        {:set_cluster, :cluster,
         %{enabled: true, runtime_status: :online, group: "Plant_floor", connected: []}}
      )

    assert public.cluster.group == "Plant_floor"
  end

  test "subnet configuration returns a local action that replicas can discard" do
    operation =
      {:configure_subnet_router, :subnet_router, %{enabled: true, routes: ["192.168.10.0/24"]}}

    assert {:ok, configured, actions} = Data.apply_operation(data(), operation)
    assert :broadcast in actions
    assert {:apply_subnet_router, true, ["192.168.10.0/24"]} in actions

    assert {:ok, replica, _discarded_actions} = Data.apply_operation(data(), operation)
    assert configured == replica
  end

  test "SSH configuration returns a local action that replicas can discard" do
    operation = {:configure_ssh, :ssh, %{enabled: true}}

    assert {:ok, configured, actions} = Data.apply_operation(data(), operation)
    assert :broadcast in actions
    assert {:configure_ssh, true} in actions
    assert configured.ssh.enabled
    assert configured.ssh.state == :waiting_for_tailnet

    assert {:ok, replica, _discarded_actions} = Data.apply_operation(data(), operation)
    assert configured == replica
  end

  test "SSH observations reject wildcard and non-Tailscale listeners" do
    data =
      data()
      |> apply!(
        {:set_tailnet, :tailnet,
         %{
           observed_status: :online,
           authenticated: true,
           hostname: "gate-a",
           ipv4: "100.84.12.7"
         }}
      )
      |> apply!({:configure_ssh, :ssh, %{enabled: true}})

    for address <- [:any, {0, 0, 0, 0}, {192, 168, 1, 20}] do
      operation =
        {:observe_ssh, :ssh, %{enabled: true, state: :listening, address: address, port: 22}}

      assert :error = Data.apply_operation(data, operation)
    end

    online =
      apply!(
        data,
        {:observe_ssh, :ssh,
         %{enabled: true, state: :listening, address: {100, 84, 12, 7}, port: 22}}
      )

    assert online.ssh.address == {100, 84, 12, 7}
  end

  test "subnet routing accepts only canonical public fields" do
    operation =
      {:configure_subnet_router, :subnet_router,
       %{
         enabled: true,
         routes: ["192.168.10.0/24"],
         credential: "must-not-replicate"
       }}

    assert :error = Data.apply_operation(data(), operation)

    public =
      data()
      |> apply!(
        {:configure_subnet_router, :subnet_router, %{enabled: true, routes: ["192.168.10.0/24"]}}
      )
      |> apply!(
        {:observe_subnet_router, :subnet_router,
         %{advertised: [], approved: [], primary: [], error: :awaiting_approval}}
      )

    assert public.subnet_router.status == :blocked
    refute inspect(public) =~ "must-not-replicate"
  end

  test "malformed and unknown operations are rejected" do
    assert :error = Data.apply_operation(data(), {:set_internet, :internet, %{status: :maybe}})
    assert :error = Data.apply_operation(data(), {:set_name, "private-origin", "Gate A"})
    assert :error = Data.apply_operation(data(), {:unknown, :test})
  end

  defp data do
    Data.new(device_id: "gate-a", name: "Gate A", firmware_version: "1.0.0")
  end

  defp apply!(data, operation) do
    assert {:ok, data, actions} = Data.apply_operation(data, operation)
    assert :broadcast in actions
    data
  end
end

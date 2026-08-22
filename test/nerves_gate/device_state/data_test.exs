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
      {:set_cluster, :cluster,
       %{
         runtime_status: :online,
         enabled: true,
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
        {:set_cluster, :cluster,
         %{
           runtime_status: :online,
           enabled: true,
           node: "nervesgate@100.64.0.10",
           connected: []
         }}
      )
      |> apply!({:set_internet, :internet, %{status: :failed, reason: :no_carrier}})

    assert data.internet.status == :failed
    assert data.tailnet.status == :blocked
    assert data.tailnet.observed_status == :online
    assert data.cluster.status == :blocked

    recovered = apply!(data, {:set_internet, :internet, %{status: :online, reason: nil}})
    assert recovered.tailnet.status == :online
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
         cookie: "must-not-replicate"
       }}

    assert :error = Data.apply_operation(data, operation)
    refute inspect(data) =~ "must-not-replicate"
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
    assert actions == [:broadcast]
    data
  end
end

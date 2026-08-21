defmodule NervesGate.DeviceState.PublicTest do
  use ExUnit.Case, async: true

  alias NervesGate.DeviceState.Public

  test "singular mode starts disabled rather than unhealthy" do
    assert public().cluster.status == :disabled
  end

  test "the pure reducer produces identical state from the same operation stream" do
    operations = [
      {:internet_changed, %{status: :online, reason: nil}},
      {:tailnet_changed,
       %{
         status: :online,
         observed_status: :online,
         authenticated: true,
         hostname: "gate-a",
         ipv4: "100.64.0.10"
       }},
      {:cluster_changed,
       %{
         status: :online,
         runtime_status: :online,
         enabled: true,
         node: "nervesgate@100.64.0.10",
         connected: []
       }},
      {:name_changed, "Boiler room"},
      {:alarm_set, %{id: "Internet.Alarm", description: "Internet unavailable", level: :warning}}
    ]

    left = Enum.reduce(operations, public(), &Public.reduce(&2, &1))
    right = Enum.reduce(operations, public(), &Public.reduce(&2, &1))

    assert left == right
    assert left.name == "Boiler room"
    assert left.internet.status == :online
    assert left.tailnet.status == :online
    assert left.cluster.status == :online
  end

  test "downstream public layers become blocked without losing their observations" do
    data =
      public()
      |> Public.reduce({:internet_changed, %{status: :online, reason: nil}})
      |> Public.reduce(
        {:tailnet_changed,
         %{
           status: :online,
           observed_status: :online,
           authenticated: true,
           hostname: "gate-a",
           ipv4: "100.64.0.10"
         }}
      )
      |> Public.reduce(
        {:cluster_changed,
         %{
           status: :online,
           runtime_status: :online,
           enabled: true,
           node: "nervesgate@100.64.0.10",
           connected: []
         }}
      )
      |> Public.reduce({:internet_changed, %{status: :failed, reason: :no_carrier}})

    assert data.internet.status == :failed
    assert data.tailnet.status == :blocked
    assert data.tailnet.observed_status == :online
    assert data.cluster.status == :blocked

    recovered = Public.reduce(data, {:internet_changed, %{status: :online, reason: nil}})
    assert recovered.tailnet.status == :online
    assert recovered.cluster.status == :online
  end

  test "alarm operations are deterministic and secret-free" do
    alarm = %{id: "Cluster.Alarm", description: "Cluster unavailable", level: :warning}
    data = Public.reduce(public(), {:alarm_set, alarm})

    assert data.alarms == [alarm]
    assert Public.reduce(data, {:alarm_set, alarm}) == data
    assert Public.reduce(data, {:alarm_cleared, alarm.id}).alarms == []
    refute Map.has_key?(Public.to_map(data), :cookie)

    sanitized =
      Public.reduce(data, {
        :cluster_changed,
        %{enabled: true, runtime_status: :online, connected: [], cookie: "must-not-replicate"}
      })

    refute Map.has_key?(sanitized.cluster, :cookie)
    refute inspect(sanitized) =~ "must-not-replicate"
  end

  defp public do
    %Public{
      device_id: "gate-a",
      name: "Gate A",
      boot_id: "boot-a",
      firmware_version: "1.0.0"
    }
  end
end

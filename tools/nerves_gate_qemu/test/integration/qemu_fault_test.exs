defmodule NervesGateQEMU.ResilienceIntegrationTest do
  use NervesGateQEMU.IntegrationCase, async: false

  @moduletag :integration
  @moduletag timeout: 300_000

  test "three commissioned gateways form one fully replicated mesh", %{cluster: cluster} do
    Enum.each(cluster.devices, fn device ->
      status = Harness.fetch!(device)
      assert Gateway.ready?(status)

      expected = Map.values(cluster.ids) -- [Map.fetch!(cluster.ids, device.id)]

      assert Enum.all?(expected, fn id ->
               match?(%{"connected" => true}, Gateway.replica(status, id))
             end)
    end)
  end

  test "an unkept backend settings update rolls back and rejoins the mesh", %{
    cluster: cluster
  } do
    victim = hd(cluster.devices)
    before = Harness.fetch!(victim)
    accepted_revision = Gateway.accepted_revision(before)

    accepted_group =
      get_in(before, ["local", "state", "configuration", "current", "cluster_group"])

    temporary_group = "#{accepted_group}_temporary"

    assert :ok =
             Gateway.command(victim, "update/cluster", %{
               "cluster" => %{"group" => temporary_group},
               "connection_id" => "qemu-temporary-update",
               "timeout" => 2_000
             })

    temporary =
      Harness.await!("#{victim.id} temporary cluster settings", fn ->
        case Gateway.fetch(victim) do
          {:ok, status} ->
            state = Gateway.state(status)
            pending = get_in(state, ["configuration", "pending"])

            if get_in(pending || %{}, ["candidate", "cluster_group"]) == temporary_group and
                 get_in(state, ["cluster", "group"]) == temporary_group,
               do: {:ok, status},
               else: {:retry, Gateway.summary(status)}

          {:error, reason} ->
            {:retry, reason}
        end
      end)

    assert get_in(temporary, ["local", "state", "configuration", "current", "cluster_group"]) ==
             accepted_group

    restored =
      Harness.await!("#{victim.id} automatic settings rollback", fn ->
        case Gateway.fetch(victim) do
          {:ok, status} ->
            state = Gateway.state(status)

            if is_nil(get_in(state, ["configuration", "pending"])) and
                 get_in(state, ["cluster", "group"]) == accepted_group and
                 Gateway.ready?(status),
               do: {:ok, status},
               else: {:retry, Gateway.summary(status)}

          {:error, reason} ->
            {:retry, reason}
        end
      end)

    assert Gateway.accepted_revision(restored) == accepted_revision
    Harness.await_mesh!(cluster)
  end

  test "uplink loss preserves accepted settings, marks replicas stale, and heals", %{
    cluster: cluster
  } do
    victim = hd(cluster.devices)
    before = Harness.fetch!(victim)
    accepted_revision = Gateway.accepted_revision(before)

    disconnected_at = System.monotonic_time(:millisecond)
    assert :ok = Fault.link_down(victim.id)

    Enum.each(Harness.peers(cluster, victim.id), fn peer ->
      replica = Harness.await_replica!(cluster, peer.id, victim.id, false, 10_000)
      assert replica["state"]["configuration"]["configured"] == true
    end)

    assert System.monotonic_time(:millisecond) - disconnected_at < 10_000

    disconnected =
      Harness.await!("#{victim.id} offline Internet evidence", fn ->
        case Gateway.fetch(victim) do
          {:ok, status} ->
            state = Gateway.state(status)

            if Gateway.configured?(status) and get_in(state, ["internet", "state"]) == "offline",
              do: {:ok, status},
              else: {:retry, Gateway.summary(status)}

          {:error, reason} ->
            {:retry, reason}
        end
      end)

    assert Gateway.configured?(disconnected)
    assert Gateway.accepted_revision(disconnected) == accepted_revision

    assert :ok = Fault.heal(victim.id)
    recovered = Harness.await_ready!(cluster, victim.id)
    assert Gateway.configured?(recovered)
    assert Gateway.accepted_revision(recovered) == accepted_revision
    Harness.await_mesh!(cluster)
  end

  test "hard restart retains accepted intent and replicas resynchronize to the new boot", %{
    cluster: cluster
  } do
    victim = Enum.at(cluster.devices, 1)
    before = Harness.fetch!(victim)
    old_boot_id = Gateway.boot_id(before)
    accepted_revision = Gateway.accepted_revision(before)

    assert :ok = Runner.restart(victim.id)

    recovered =
      Harness.await!("#{victim.id} restart with a new DeviceState boot ID", fn ->
        case Gateway.fetch(victim) do
          {:ok, status} ->
            if Gateway.ready?(status) and Gateway.boot_id(status) != old_boot_id,
              do: {:ok, status},
              else: {:retry, Gateway.summary(status)}

          {:error, reason} ->
            {:retry, reason}
        end
      end)

    assert Gateway.configured?(recovered)
    assert Gateway.accepted_revision(recovered) == accepted_revision

    Enum.each(Harness.peers(cluster, victim.id), fn observer ->
      replica =
        Harness.await_replica_boot!(
          cluster,
          observer.id,
          victim.id,
          Gateway.boot_id(recovered)
        )

      assert replica["boot_id"] == Gateway.boot_id(recovered)
    end)
  end

  test "a stopped VM remains as a stale replica and rejoins without commissioning", %{
    cluster: cluster
  } do
    victim = List.last(cluster.devices)
    accepted_revision = victim |> Harness.fetch!() |> Gateway.accepted_revision()

    assert :ok = Runner.stop(victim.id)

    Enum.each(Harness.peers(cluster, victim.id), fn observer ->
      stale = Harness.await_replica!(cluster, observer.id, victim.id, false, 120_000)
      assert stale["state"]["configuration"]["configured"] == true
    end)

    assert :ok = Runner.start(victim.id)
    recovered = Harness.await_ready!(cluster, victim.id)
    assert Gateway.configured?(recovered)
    assert Gateway.accepted_revision(recovered) == accepted_revision
    Harness.await_mesh!(cluster)
  end
end

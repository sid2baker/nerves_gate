defmodule NervesGateQEMU.ResilienceIntegrationTest do
  use NervesGateQEMU.IntegrationCase, async: false

  @moduletag :integration
  @moduletag timeout: 2_400_000

  setup do
    NervesGateQEMU.ReleaseServer.select("0.2.0")
    NervesGateQEMU.ReleaseServer.normal()
    :ok
  end

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

  test "signed trial firmware survives release, power, boot, network, and acceptance faults", %{
    cluster: cluster
  } do
    victim = hd(cluster.devices)
    peers = Harness.peers(cluster, victim.id)

    # TCG is CPU-bound. Keep the firmware contract test deterministic by
    # dedicating the host to the updating gateway, then restore the mesh before
    # the scenario commits. Cluster health is not a trial acceptance check.
    Enum.each(peers, &assert(:ok = Runner.stop(&1.id)))

    # Signed but incompatible metadata never becomes an available update.
    NervesGateQEMU.ReleaseServer.select("wrong")
    assert :ok = Gateway.firmware_command(victim, "check", %{})

    await_firmware(
      victim,
      &(&1["phase"] in ["idle", "ready"] and is_nil(&1["available"])),
      "wrong-system firmware rejection"
    )

    NervesGateQEMU.ReleaseServer.select("0.2.0")
    release = discover_update!(victim, "0.2.0")

    # Corrupt and interrupted artifacts stop before the platform installer.
    NervesGateQEMU.ReleaseServer.corrupt()
    assert :ok = prepare_firmware(victim, release)
    await_firmware_failure(victim, "artifact_digest_mismatch")

    NervesGateQEMU.ReleaseServer.truncate_after(1024 * 1024)
    assert :ok = prepare_firmware(victim, release)
    await_firmware_failure(victim, "artifact_size_mismatch")

    NervesGateQEMU.ReleaseServer.normal()
    assert :ok = prepare_firmware(victim, release)
    await_firmware(victim, &(&1["phase"] == "ready"), "resumed verified download")

    # A hard power cut after installation intent never damages the active slot.
    assert :ok = install_firmware(victim, release)
    await_firmware(victim, &(&1["phase"] == "installing"), "installation write start")
    assert :ok = Runner.power_cut(victim.id)
    assert :ok = Runner.start(victim.id)
    await_version(victim, "0.1.0", "known-good boot after installation power loss")

    # An unvalidated reboot models a candidate that cannot complete boot.
    release = discover_update!(victim, "0.2.0")
    trial = install_trial!(victim, release, "0.2.0")
    assert trial["validation"] == "trial"
    assert :ok = Runner.power_cut(victim.id)
    assert :ok = Runner.start(victim.id)
    await_version(victim, "0.1.0", "automatic boot fallback")

    # Loss of the management network during trial triggers application rollback.
    release = discover_update!(victim, "0.2.0")
    _trial = install_trial!(victim, release, "0.2.0")
    await_firmware(victim, &get_in(&1, ["trial", "confirmable"]), "healthy trial")
    assert :ok = Fault.link_down(victim.id)
    await_version(victim, "0.1.0", "rollback after management loss", 300_000)
    assert :ok = Fault.heal(victim.id)
    Harness.await_ready!(cluster, victim.id)

    # The operator can reject a trial immediately.
    release = discover_update!(victim, "0.2.0")
    trial = install_trial!(victim, release, "0.2.0")

    assert :ok =
             Gateway.firmware_command(victim, "rollback", %{"trial_id" => trial["trial"]["id"]})

    await_version(victim, "0.1.0", "explicit rollback", 120_000)

    # Missing confirmation expires the compiled five-minute QEMU trial window.
    release = discover_update!(victim, "0.2.0")
    _trial = install_trial!(victim, release, "0.2.0")
    await_version(victim, "0.1.0", "unconfirmed trial rollback", 420_000)

    # A healthy trial is committed only by a fresh Tailnet request.
    release = discover_update!(victim, "0.2.0")
    trial = install_trial!(victim, release, "0.2.0")
    await_firmware(victim, &get_in(&1, ["trial", "confirmable"]), "confirmable firmware")
    assert :ok = Gateway.firmware_command(victim, "accept", %{"trial_id" => trial["trial"]["id"]})
    await_validated(victim, "0.2.0")

    # The same generic contract remains usable for a subsequent signed upgrade.
    NervesGateQEMU.ReleaseServer.select("0.3.0")
    release = discover_update!(victim, "0.3.0")
    trial = install_trial!(victim, release, "0.3.0")
    await_firmware(victim, &get_in(&1, ["trial", "confirmable"]), "second confirmable firmware")
    assert :ok = Gateway.firmware_command(victim, "accept", %{"trial_id" => trial["trial"]["id"]})
    await_validated(victim, "0.3.0")
    Enum.each(peers, &assert(:ok = Runner.start(&1.id)))
    Enum.each(peers, &Harness.await_ready!(cluster, &1.id))
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

  defp discover_update!(device, version) do
    Harness.await!(
      "#{device.id} readiness before firmware discovery",
      fn -> readiness_observation(device) end
    )

    assert :ok = Gateway.firmware_command(device, "check", %{})

    firmware =
      await_firmware(
        device,
        &(&1["phase"] in ["idle", "ready", "failed"] and
            get_in(&1, ["available", "version"]) == version),
        "firmware #{version} discovery"
      )

    firmware["available"]
  end

  defp readiness_observation(device) do
    case Gateway.fetch(device) do
      {:ok, status} ->
        if Gateway.ready?(status),
          do: {:ok, status},
          else: {:retry, Gateway.summary(status)}

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp prepare_firmware(device, release) do
    Gateway.firmware_command(device, "prepare", %{
      "release_id" => release["id"],
      "connection_id" => "qemu-download-#{System.unique_integer([:positive])}"
    })
  end

  defp install_firmware(device, release) do
    Gateway.firmware_command(device, "install", %{
      "release_id" => release["id"],
      "connection_id" => "qemu-install-#{System.unique_integer([:positive])}"
    })
  end

  defp install_trial!(device, release, version) do
    assert :ok = prepare_firmware(device, release)
    await_firmware(device, &(&1["phase"] == "ready"), "verified firmware #{version}")
    attempt_install!(device, release, version, 5)
  end

  defp attempt_install!(device, release, version, attempts) do
    boot_id = device |> Harness.fetch!() |> Gateway.boot_id()
    assert :ok = install_firmware(device, release)

    case await_install_outcome(device, version, boot_id) do
      {:trial, firmware} ->
        firmware

      {:retry, _firmware} when attempts > 1 ->
        attempt_install!(device, release, version, attempts - 1)

      {:retry, firmware} ->
        flunk("firmware installation exhausted retries: #{inspect(firmware)}")
    end
  end

  defp await_install_outcome(device, version, boot_id) do
    Harness.await!(
      "trial firmware #{version}",
      fn -> install_observation(device, version, boot_id) end,
      timeout: 300_000,
      interval: 500
    )
  end

  defp install_observation(device, version, boot_id) do
    case Gateway.fetch(device) do
      {:ok, status} ->
        firmware = Gateway.firmware(status)

        cond do
          trial_firmware?(firmware, version) -> {:ok, {:trial, firmware}}
          retryable_install_failure?(firmware) -> {:ok, {:retry, firmware}}
          fallback_observed?(status, firmware, version, boot_id) -> {:ok, {:retry, firmware}}
          true -> {:retry, firmware}
        end

      {:error, reason} ->
        {:retry, reason}
    end
  end

  defp trial_firmware?(firmware, version) do
    firmware["validation"] == "trial" and
      get_in(firmware, ["current", "version"]) == version
  end

  defp retryable_install_failure?(firmware) do
    firmware["phase"] == "ready" and
      firmware["last_error"] in [
        "installer_unavailable",
        "operation_crashed",
        "preflight_failed"
      ]
  end

  defp fallback_observed?(status, firmware, version, boot_id) do
    firmware["phase"] == "ready" and Gateway.boot_id(status) != boot_id and
      get_in(firmware, ["current", "version"]) != version
  end

  defp await_firmware_failure(device, expected) do
    await_firmware(
      device,
      &(&1["phase"] == "failed" and &1["last_error"] == expected),
      "firmware failure #{expected}"
    )
  end

  defp await_version(device, version, description, timeout \\ 180_000) do
    await_firmware(
      device,
      &(&1["validation"] == "validated" and get_in(&1, ["current", "version"]) == version),
      description,
      timeout
    )
  end

  defp await_validated(device, version),
    do: await_version(device, version, "validated firmware #{version}")

  defp await_firmware(device, predicate, description, timeout \\ 180_000) do
    Harness.await!(
      description,
      fn -> firmware_observation(device, predicate) end,
      timeout: timeout,
      interval: 500
    )
  end

  defp firmware_observation(device, predicate) do
    case Gateway.fetch(device) do
      {:ok, status} ->
        firmware = Gateway.firmware(status)
        if predicate.(firmware), do: {:ok, firmware}, else: {:retry, firmware}

      {:error, reason} ->
        {:retry, reason}
    end
  end
end

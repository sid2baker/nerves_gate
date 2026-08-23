defmodule NervesGate.ConfigurationTest do
  use ExUnit.Case, async: false

  alias NervesGate.Configuration
  alias NervesGate.Store
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:configuration)
    owner = self()

    ops = [
      internet: fn config ->
        send(owner, {:internet, config})
        {:ok, TestScenario.checks()}
      end,
      internet_restore: fn config ->
        send(owner, {:internet_restore, config})
        :ok
      end,
      stage_tailnet: fn token, _id, previous ->
        send(owner, {:stage_tailnet, token, previous})

        {:ok,
         %{
           "previous_profile_id" => previous,
           "candidate_profile_id" => "candidate-profile"
         }}
      end,
      tailnet_restore: fn profile_id ->
        send(owner, {:tailnet_restore, profile_id})
        :ok
      end,
      commit_tailnet: fn metadata ->
        send(owner, {:commit_tailnet, metadata})
        :ok
      end,
      rollback_tailnet: fn metadata ->
        send(owner, {:rollback_tailnet, metadata})
        :ok
      end,
      poll_tailnet: fn -> :ok end,
      cluster: fn group ->
        send(owner, {:cluster, group})
        :ok
      end,
      access: fn mode, interface ->
        send(owner, {:access, mode, interface})
        {:ok, []}
      end,
      disable_access: fn ->
        send(owner, :disable_access)
        :ok
      end
    ]

    on_exit(fn ->
      NervesGate.Alarms.clear(NervesGate.Configuration.Signal.Changing)
      NervesGate.Storage.Alarms.failure(false)
      File.rm_rf!(root)
    end)

    %{root: root, ops: ops}
  end

  test "initialization always creates one settings file per firmware slot", context do
    configuration = start_configuration(context)

    assert Configuration.configured?(configuration) == false
    assert settings(context.root, "a")["firmware"] == tag("a", "firmware-a")
    assert settings(context.root, "b")["firmware"] == tag("b", "firmware-b")
    refute File.exists?(Store.candidate_path(context.root))
  end

  test "first-time setup can run without an automatic revert timer", context do
    configuration = start_configuration(context)

    assert {:ok, pending} =
             Configuration.stage_internet(internet_params(), "connection-a", 20, configuration)

    assert pending.remaining_seconds == nil
    Process.sleep(75)
    assert Configuration.status(nil, configuration).pending.id == pending.id
    assert :ok = Configuration.revert(pending.id, configuration)
  end

  test "completed steps can be edited without rolling back the candidate", context do
    configuration = start_configuration(context)

    {:ok, internet} =
      Configuration.stage_internet(internet_params(), "connection-a", nil, configuration)

    {:ok, cluster} =
      Configuration.stage_tailnet(internet.id, tailnet_params(), configuration)

    updated_internet =
      internet_params()
      |> put_in(["device", "name"], "Updated gateway")

    assert {:ok, pending} =
             Configuration.update_internet(cluster.id, updated_internet, configuration)

    assert pending.phase == :cluster
    assert pending.candidate.name == "Updated gateway"
    assert pending.candidate.tailnet_configured

    assert {:ok, pending} = Configuration.stage_tailnet(pending.id, %{}, configuration)
    assert pending.phase == :cluster
    assert pending.candidate.tailnet_configured
  end

  test "a stale timer cannot revert a candidate after an edit resets its deadline", context do
    configuration = start_configuration(context)
    accept_initial(configuration)

    {:ok, pending} =
      Configuration.stage_internet(internet_params(), "connection-a", 60_000, configuration)

    old_timer_token = :sys.get_state(configuration).pending.timer_token

    assert {:ok, _pending} =
             Configuration.update_internet(pending.id, internet_params(), configuration)

    send(configuration, {:revert_timeout, pending.id, old_timer_token})
    Process.sleep(10)
    assert Configuration.status(nil, configuration).pending.id == pending.id
    assert :ok = Configuration.revert(pending.id, configuration)
  end

  test "a candidate only replaces the running slot after fresh-connection acceptance", context do
    configuration = start_configuration(context)

    assert {:ok, internet_pending} =
             Configuration.stage_internet(
               internet_params(),
               "connection-a",
               60_000,
               configuration
             )

    assert internet_pending.phase == :tailnet
    refute Configuration.status(nil, configuration).pending.confirmable
    assert File.exists?(Store.candidate_path(context.root))
    assert settings(context.root, "a")["configured"] == false
    assert candidate(context.root)["internet"]["method"] == "dhcp"
    assert candidate(context.root)["tailnet"]["profile_id"] == nil
    assert candidate(context.root)["cluster"]["group"] == nil

    assert {:error, :configuration_incomplete} =
             Configuration.confirm(internet_pending.id, "connection-b", configuration)

    assert {:ok, tailnet_pending} =
             Configuration.stage_tailnet(
               internet_pending.id,
               tailnet_params(),
               configuration
             )

    assert tailnet_pending.phase == :cluster
    assert candidate(context.root)["tailnet"]["profile_id"] == "candidate-profile"

    assert {:ok, pending} =
             Configuration.stage_cluster(
               tailnet_pending.id,
               cluster_params(),
               configuration
             )

    assert pending.phase == :confirmation
    assert Configuration.status("connection-b", configuration).pending.confirmable
    assert candidate(context.root)["cluster"]["group"] == "Field_group"

    assert {:error, :fresh_connection_required} =
             Configuration.confirm(pending.id, "connection-a", configuration)

    assert :ok = Configuration.confirm(pending.id, "connection-b", configuration)
    active = settings(context.root, "a")
    assert active["configured"]
    assert active["internet"]["method"] == "dhcp"
    assert active["cluster"]["group"] == "Field_group"
    assert active["tailnet"]["profile_id"] == "candidate-profile"
    assert active["name"] == "Pump room gateway"
    assert settings(context.root, "b")["configured"] == false
    refute File.exists?(Store.candidate_path(context.root))
    refute File.exists?(Path.join(context.root, "device.json"))
    assert_receive {:commit_tailnet, _metadata}
  end

  test "the deadline removes the candidate and restores the slot settings", context do
    configuration = start_configuration(context)
    accept_initial(configuration)
    accepted = settings(context.root, "a")

    assert {:ok, _pending} = stage_complete(configuration, 50)

    assert_eventually(fn -> Configuration.status(nil, configuration).pending == nil end)
    assert settings(context.root, "a") == accepted
    refute File.exists?(Store.candidate_path(context.root))
    assert_receive {:rollback_tailnet, %{"candidate_profile_id" => "candidate-profile"}}
    assert_receive {:internet_restore, %NervesGate.Internet.Config{}}
    assert_receive {:cluster, "Field_group"}
  end

  test "restart discards an unconfirmed candidate", context do
    configuration = start_configuration(context)
    assert {:ok, _pending} = stage_complete(configuration)
    GenServer.stop(configuration)
    assert File.exists?(Store.candidate_path(context.root))

    restarted = start_configuration(context)
    assert Configuration.status(nil, restarted).pending == nil
    refute File.exists?(Store.candidate_path(context.root))
    assert settings(context.root, "a")["configured"] == false
  end

  test "a corrupt candidate is quarantined and ignored on restart", context do
    configuration = start_configuration(context)
    GenServer.stop(configuration)
    File.write!(Store.candidate_path(context.root), "not-json")

    restarted = start_configuration(context)

    assert Configuration.status(nil, restarted).pending == nil
    refute File.exists?(Store.candidate_path(context.root))

    assert [_quarantined] =
             Path.wildcard(Store.candidate_path(context.root) <> ".corrupt-*")
  end

  test "a corrupt active slot inherits the other accepted slot", context do
    configuration = start_configuration(context)
    {:ok, pending} = stage_complete(configuration)
    :ok = Configuration.confirm(pending.id, "connection-b", configuration)
    GenServer.stop(configuration)

    slot_b =
      start_configuration(Map.put(context, :firmware, firmware("b", "firmware-a", "firmware-b")))

    GenServer.stop(slot_b)
    File.write!(Store.settings_path("a", context.root), "not-json")

    recovered = start_configuration(context)

    assert Configuration.configured?(recovered)
    assert settings(context.root, "a")["cluster"]["group"] == "Field_group"

    assert [_quarantined] =
             Path.wildcard(Store.settings_path("a", context.root) <> ".corrupt-*")
  end

  test "a newly booted firmware slot inherits and retags the other slot", context do
    configuration = start_configuration(context)
    {:ok, pending} = stage_complete(configuration)
    :ok = Configuration.confirm(pending.id, "connection-b", configuration)
    GenServer.stop(configuration)

    firmware = firmware("b", "firmware-a", "firmware-b-v2")
    migrated = start_configuration(Map.put(context, :firmware, firmware))

    assert Configuration.configured?(migrated)
    active = settings(context.root, "b")
    assert active["firmware"] == tag("b", "firmware-b-v2")
    assert active["cluster"]["group"] == "Field_group"
    assert_receive {:tailnet_restore, "candidate-profile"}
  end

  defp start_configuration(context) do
    firmware = Map.get(context, :firmware, firmware("a", "firmware-a", "firmware-b"))
    name = String.to_atom("configuration_#{System.unique_integer([:positive])}")

    {:ok, configuration} =
      Configuration.start_link(
        name: name,
        root: context.root,
        firmware: fn -> firmware end,
        ops: context.ops,
        keep_local_access: false
      )

    on_exit(fn -> if Process.alive?(configuration), do: GenServer.stop(configuration) end)
    configuration
  end

  defp accept_initial(configuration) do
    {:ok, pending} = stage_complete(configuration)
    :ok = Configuration.confirm(pending.id, "connection-b", configuration)
    :ok
  end

  defp stage_complete(configuration, timeout \\ 60_000) do
    with {:ok, internet} <-
           Configuration.stage_internet(
             internet_params(),
             "connection-a",
             timeout,
             configuration
           ),
         {:ok, tailnet} <-
           Configuration.stage_tailnet(internet.id, tailnet_params(), configuration) do
      Configuration.stage_cluster(tailnet.id, cluster_params(), configuration)
    end
  end

  defp internet_params do
    %{
      "device" => %{"name" => "Pump room gateway"},
      "internet" => %{"method" => "dhcp"}
    }
  end

  defp tailnet_params, do: %{"auth_token" => "tskey-auth-candidate"}
  defp cluster_params, do: %{"cluster" => %{"group" => "Field_group"}}

  defp firmware(active, a_uuid, b_uuid) do
    %{
      active: active,
      slots: %{
        "a" => tag("a", a_uuid),
        "b" => tag("b", b_uuid)
      }
    }
  end

  defp tag(slot, uuid), do: %{"slot" => slot, "uuid" => uuid, "version" => "1.0.0"}

  defp settings(root, slot) do
    {:ok, value} =
      Store.read_json(Store.settings_path(slot, root), &Configuration.validate_settings/1, nil)

    value
  end

  defp candidate(root) do
    {:ok, value} =
      Store.read_json(Store.candidate_path(root), &Configuration.validate_settings/1, nil)

    value
  end

  defp assert_eventually(predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not converge")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end
end

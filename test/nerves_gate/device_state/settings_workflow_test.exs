defmodule NervesGate.DeviceState.SettingsWorkflowTest do
  use ExUnit.Case, async: false

  alias NervesGate.DeviceState.Server
  alias NervesGate.Gateway.{Persistence, Settings}
  alias NervesGate.Storage
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:server)
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
      subnet_router: fn enabled, routes ->
        send(owner, {:subnet_router, enabled, routes})

        canonical =
          Enum.map(routes, fn
            "192.168.10.42/24" -> "192.168.10.0/24"
            route -> route
          end)

        {:ok, canonical}
      end,
      ssh: fn enabled ->
        send(owner, {:ssh, enabled})
        :ok
      end,
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
      NervesGate.Alarms.clear(NervesGate.DeviceState.Signal.Changing)
      NervesGate.Storage.Alarms.failure(false)
      NervesGate.SubnetRouter.Alarms.failure(false)
      File.rm_rf!(root)
    end)

    %{root: root, ops: ops}
  end

  test "initialization always creates one settings file per firmware slot", context do
    server = start_server(context)

    assert Server.configured?(server) == false
    assert settings(context.root, "a")["firmware"] == tag("a", "firmware-a")
    assert settings(context.root, "b")["firmware"] == tag("b", "firmware-b")
    refute settings(context.root, "a")["ssh_enabled"]
    refute settings(context.root, "b")["ssh_enabled"]
    refute File.exists?(Persistence.candidate_path(context.root))
  end

  test "slot snapshots created before subnet routing default to disabled", context do
    server = start_server(context)
    legacy = context.root |> settings("a") |> Map.delete("subnet_router")

    assert {:ok, validated} = Settings.validate(legacy)
    assert validated["subnet_router"] == %{"enabled" => false, "routes" => []}
    refute Server.configured?(server)
  end

  test "first-time setup can run without an automatic revert timer", context do
    server = start_server(context)

    assert {:ok, pending} =
             Server.stage_internet(internet_params(), "connection-a", 20, server)

    assert pending.remaining_seconds == nil
    Process.sleep(75)
    assert Server.configuration(nil, server).pending.id == pending.id
    assert :ok = Server.revert(pending.id, server)
  end

  test "completed steps can be edited without rolling back the candidate", context do
    server = start_server(context)

    {:ok, internet} =
      Server.stage_internet(internet_params(), "connection-a", nil, server)

    {:ok, cluster} =
      Server.stage_tailnet(internet.id, tailnet_params(), server)

    updated_internet =
      internet_params()
      |> put_in(["device", "name"], "Updated gateway")

    assert {:ok, pending} =
             Server.update_internet(cluster.id, updated_internet, server)

    assert pending.phase == :cluster
    assert pending.candidate.name == "Updated gateway"
    assert pending.candidate.tailnet_configured

    assert {:ok, pending} = Server.stage_tailnet(pending.id, %{}, server)
    assert pending.phase == :cluster
    assert pending.candidate.tailnet_configured
  end

  test "a stale timer cannot revert a candidate after an edit resets its deadline", context do
    server = start_server(context)
    accept_initial(server)

    {:ok, pending} =
      Server.stage_internet(internet_params(), "connection-a", 60_000, server)

    old_timer_token = :sys.get_state(server).pending.timer_token

    assert {:ok, _pending} =
             Server.update_internet(pending.id, internet_params(), server)

    send(server, {:revert_timeout, pending.id, old_timer_token})
    Process.sleep(10)
    assert Server.configuration(nil, server).pending.id == pending.id
    assert :ok = Server.revert(pending.id, server)
  end

  test "a candidate only replaces the running slot after fresh-connection acceptance", context do
    server = start_server(context)

    assert {:ok, internet_pending} =
             Server.stage_internet(
               internet_params(),
               "connection-a",
               60_000,
               server
             )

    assert internet_pending.phase == :tailnet
    refute Server.configuration(nil, server).pending.confirmable
    assert File.exists?(Persistence.candidate_path(context.root))
    assert settings(context.root, "a")["configured"] == false
    assert candidate(context.root)["internet"]["method"] == "dhcp"
    assert candidate(context.root)["tailnet"]["profile_id"] == nil
    assert candidate(context.root)["cluster"]["group"] == nil

    assert {:error, :configuration_incomplete} =
             Server.confirm(internet_pending.id, "connection-b", server)

    assert {:ok, tailnet_pending} =
             Server.stage_tailnet(
               internet_pending.id,
               tailnet_params(),
               server
             )

    assert tailnet_pending.phase == :cluster
    assert candidate(context.root)["tailnet"]["profile_id"] == "candidate-profile"

    assert {:ok, pending} =
             Server.stage_cluster(
               tailnet_pending.id,
               cluster_params(),
               server
             )

    assert pending.phase == :confirmation
    assert Server.configuration("connection-b", server).pending.confirmable
    assert candidate(context.root)["cluster"]["group"] == "Field_group"

    assert {:error, :fresh_connection_required} =
             Server.confirm(pending.id, "connection-a", server)

    assert :ok = Server.confirm(pending.id, "connection-b", server)
    active = settings(context.root, "a")
    assert active["configured"]
    assert active["internet"]["method"] == "dhcp"
    assert active["cluster"]["group"] == "Field_group"
    assert active["tailnet"]["profile_id"] == "candidate-profile"
    assert active["name"] == "Pump room gateway"
    assert settings(context.root, "b")["configured"] == false
    refute File.exists?(Persistence.candidate_path(context.root))
    refute File.exists?(Path.join(context.root, "device.json"))
    assert_receive {:commit_tailnet, _metadata}
  end

  test "subnet routing updates immediately without a commissioning candidate", context do
    server = start_server(context)
    accept_initial(server)
    assert_receive {:subnet_router, false, []}
    assert {:ok, _snapshot} = Server.join(self(), server)

    assert {:error, :invalid_subnet_routes} =
             Server.configure_subnet_router(true, ["not-a-cidr"], server)

    refute_receive {:subnet_router, true, _routes}

    assert {:ok, %{enabled: true, routes: ["192.168.10.0/24"]}} =
             Server.configure_subnet_router(
               true,
               ["192.168.10.42/24"],
               server
             )

    assert Server.configuration(nil, server).pending == nil
    assert Server.data(server).subnet_router.enabled
    assert Server.data(server).subnet_router.routes == ["192.168.10.0/24"]

    assert_receive {:device_state_operation, _node, _boot_id, _revision,
                    {:configure_subnet_router, :subnet_router, %{enabled: true}}}

    assert settings(context.root, "a")["subnet_router"] == %{
             "enabled" => true,
             "routes" => ["192.168.10.0/24"]
           }

    assert_receive {:subnet_router, true, ["192.168.10.0/24"]}

    GenServer.stop(server)
    server = start_server(context)
    assert_receive {:subnet_router, true, ["192.168.10.0/24"]}

    assert {:ok, %{enabled: false, routes: ["192.168.10.0/24"]}} =
             Server.configure_subnet_router(false, [], server)

    assert settings(context.root, "a")["subnet_router"] == %{
             "enabled" => false,
             "routes" => ["192.168.10.0/24"]
           }

    assert_receive {:subnet_router, false, ["192.168.10.0/24"]}
  end

  test "subnet settings are durable before their reducer action executes", context do
    owner = self()

    subnet_router = fn enabled, routes ->
      {:ok, settings} =
        Storage.read_json(
          Persistence.settings_path("a", context.root),
          &Settings.validate/1,
          nil
        )

      send(owner, {:effect_saw_settings, settings["subnet_router"]})
      {:ok, routes}
    end

    context = %{context | ops: Keyword.put(context.ops, :subnet_router, subnet_router)}
    server = start_server(context)
    accept_initial(server)

    assert {:ok, %{enabled: true}} =
             Server.configure_subnet_router(true, ["192.168.30.42/24"], server)

    assert_receive {:effect_saw_settings, %{"enabled" => true, "routes" => ["192.168.30.0/24"]}}
  end

  test "a failed subnet effect keeps the durable desired state for reconciliation", context do
    subnet_router = fn
      true, _routes -> {:error, :daemon_unavailable}
      false, routes -> {:ok, routes}
    end

    context = %{context | ops: Keyword.put(context.ops, :subnet_router, subnet_router)}
    server = start_server(context)
    accept_initial(server)

    assert {:error, {:subnet_router_apply_failed, :daemon_unavailable}} =
             Server.configure_subnet_router(true, ["192.168.40.0/24"], server)

    assert Server.current(server)["subnet_router"] == %{
             "enabled" => true,
             "routes" => ["192.168.40.0/24"]
           }

    assert Server.data(server).subnet_router.enabled
    assert Server.data(server).subnet_router.routes == ["192.168.40.0/24"]
    assert Server.data(server).subnet_router.error == :apply_failed
    assert Server.data(server).subnet_router.status == :blocked
  end

  test "SSH enablement is persisted and restored without persisting listener state", context do
    server = start_server(context)
    accept_initial(server)
    assert_receive {:ssh, false}

    assert :ok = Server.configure_ssh(true, server)
    assert_receive {:ssh, true}
    assert settings(context.root, "a")["ssh_enabled"]
    refute Map.has_key?(settings(context.root, "a"), "ssh_address")
    assert Server.data(server).ssh.enabled
    assert Server.data(server).ssh.state == :waiting_for_tailnet

    GenServer.stop(server)
    _restarted = start_server(context)
    assert_receive {:ssh, true}
  end

  test "SSH enablement cannot race a guarded remote-access change", context do
    server = start_server(context)
    accept_initial(server)

    assert {:ok, _pending} =
             Server.stage_internet(
               internet_params(),
               "connection-a",
               60_000,
               server
             )

    assert {:error, :configuration_change_in_progress} = Server.configure_ssh(true, server)
  end

  test "subnet routing cannot race a guarded remote-access change", context do
    server = start_server(context)
    accept_initial(server)

    assert {:ok, _pending} =
             Server.stage_internet(
               internet_params(),
               "connection-a",
               60_000,
               server
             )

    assert {:error, :configuration_change_in_progress} =
             Server.configure_subnet_router(true, ["192.168.10.0/24"], server)
  end

  test "the deadline removes the candidate and restores the slot settings", context do
    server = start_server(context)
    accept_initial(server)
    accepted = settings(context.root, "a")

    assert {:ok, _pending} = stage_complete(server, 50)

    assert_eventually(fn -> Server.configuration(nil, server).pending == nil end)
    assert settings(context.root, "a") == accepted
    refute File.exists?(Persistence.candidate_path(context.root))
    assert_receive {:rollback_tailnet, %{"candidate_profile_id" => "candidate-profile"}}
    assert_receive {:internet_restore, %NervesGate.Internet.Config{}}
    assert_receive {:cluster, "Field_group"}
  end

  test "restart discards an unconfirmed candidate", context do
    server = start_server(context)
    assert {:ok, _pending} = stage_complete(server)
    GenServer.stop(server)
    assert File.exists?(Persistence.candidate_path(context.root))

    restarted = start_server(context)
    assert Server.configuration(nil, restarted).pending == nil
    refute File.exists?(Persistence.candidate_path(context.root))
    assert settings(context.root, "a")["configured"] == false
  end

  test "a corrupt candidate is quarantined and ignored on restart", context do
    server = start_server(context)
    GenServer.stop(server)
    File.write!(Persistence.candidate_path(context.root), "not-json")

    restarted = start_server(context)

    assert Server.configuration(nil, restarted).pending == nil
    refute File.exists?(Persistence.candidate_path(context.root))

    assert [_quarantined] =
             Path.wildcard(Persistence.candidate_path(context.root) <> ".corrupt-*")
  end

  test "a corrupt active slot inherits the other accepted slot", context do
    server = start_server(context)
    {:ok, pending} = stage_complete(server)
    :ok = Server.confirm(pending.id, "connection-b", server)
    GenServer.stop(server)

    slot_b =
      start_server(Map.put(context, :firmware, firmware("b", "firmware-a", "firmware-b")))

    GenServer.stop(slot_b)
    File.write!(Persistence.settings_path("a", context.root), "not-json")

    recovered = start_server(context)

    assert Server.configured?(recovered)
    assert settings(context.root, "a")["cluster"]["group"] == "Field_group"

    assert [_quarantined] =
             Path.wildcard(Persistence.settings_path("a", context.root) <> ".corrupt-*")
  end

  test "a newly booted firmware slot inherits and retags the other slot", context do
    server = start_server(context)
    {:ok, pending} = stage_complete(server)
    :ok = Server.confirm(pending.id, "connection-b", server)
    GenServer.stop(server)

    firmware = firmware("b", "firmware-a", "firmware-b-v2")
    migrated = start_server(Map.put(context, :firmware, firmware))

    assert Server.configured?(migrated)
    active = settings(context.root, "b")
    assert active["firmware"] == tag("b", "firmware-b-v2")
    assert active["cluster"]["group"] == "Field_group"
    assert_receive {:tailnet_restore, "candidate-profile"}
  end

  defp start_server(context) do
    firmware = Map.get(context, :firmware, firmware("a", "firmware-a", "firmware-b"))
    name = String.to_atom("device_state_settings_#{System.unique_integer([:positive])}")

    {:ok, server} =
      Server.start_link(
        name: name,
        root: context.root,
        firmware: fn -> firmware end,
        ops: context.ops,
        keep_local_access: false
      )

    on_exit(fn -> if Process.alive?(server), do: GenServer.stop(server) end)
    server
  end

  defp accept_initial(server) do
    {:ok, pending} = stage_complete(server)
    :ok = Server.confirm(pending.id, "connection-b", server)
    :ok
  end

  defp stage_complete(server, timeout \\ 60_000) do
    with {:ok, internet} <-
           Server.stage_internet(
             internet_params(),
             "connection-a",
             timeout,
             server
           ),
         {:ok, tailnet} <-
           Server.stage_tailnet(internet.id, tailnet_params(), server) do
      Server.stage_cluster(tailnet.id, cluster_params(), server)
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
      Storage.read_json(Persistence.settings_path(slot, root), &Settings.validate/1, nil)

    value
  end

  defp candidate(root) do
    {:ok, value} =
      Storage.read_json(Persistence.candidate_path(root), &Settings.validate/1, nil)

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

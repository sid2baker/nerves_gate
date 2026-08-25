defmodule NervesGate.Gateway.ConfigurationTest do
  use ExUnit.Case, async: false

  alias NervesGate.Gateway.Configuration
  alias NervesGate.Gateway.Persistence
  alias NervesGate.Gateway.Settings
  alias NervesGate.Storage
  alias NervesGate.TestScenario

  setup do
    root = TestScenario.temporary_root(:configuration_machine)
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
      internet_observe: fn -> :ok end,
      stage_tailnet: fn token, _id, previous ->
        send(owner, {:stage_tailnet, token, previous})
        {:ok, %{"previous_profile_id" => previous, "candidate_profile_id" => "candidate-profile"}}
      end,
      tailnet_restore: fn profile ->
        send(owner, {:tailnet_restore, profile})
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
      subnet_router: fn enabled, routes, _change_id ->
        send(owner, {:subnet_router, enabled, routes})
        {:ok, routes}
      end,
      ssh: fn enabled, _change_id ->
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
      disable_access: fn -> :ok end
    ]

    on_exit(fn ->
      NervesGate.DeviceState.Alarms.changing(false)
      NervesGate.Storage.Alarms.failure(false)
      File.chmod(root, 0o700)
      File.rm_rf!(root)
    end)

    %{root: root, ops: ops}
  end

  test "boot creates tagged slot settings and exposes idle diagnostics", context do
    machine = start_machine(context)

    refute Configuration.configured?(machine)
    assert settings(context.root, "a")["firmware"] == tag("a", "firmware-a")
    assert settings(context.root, "b")["firmware"] == tag("b", "firmware-b")
    assert Configuration.diagnostics(machine).state == :idle
  end

  test "candidate advances through domain states and requires a fresh Tailnet connection",
       context do
    machine = start_machine(context)

    {:ok, internet} =
      Configuration.stage_internet(internet_params(), "connection-a", nil, machine)

    assert internet.phase == :tailnet
    assert Configuration.diagnostics(machine).state == :needs_tailnet

    {:ok, tailnet} = Configuration.stage_tailnet(internet.id, tailnet_params(), machine)
    assert tailnet.phase == :cluster
    assert Configuration.diagnostics(machine).state == :needs_cluster

    {:ok, pending} = Configuration.stage_cluster(tailnet.id, cluster_params(), machine)
    assert pending.phase == :confirmation
    assert Configuration.diagnostics(machine).state == :needs_confirmation

    assert {:error, :tailnet_connection_required} =
             Configuration.confirm(pending.id, %{id: "connection-b", tailnet?: false}, machine)

    assert {:error, :fresh_connection_required} =
             Configuration.confirm(pending.id, connection("connection-a"), machine)

    assert :ok = Configuration.confirm(pending.id, connection("connection-b"), machine)
    assert Configuration.diagnostics(machine).state == :idle
    assert Configuration.configured?(machine)
    refute File.exists?(Persistence.candidate_path(context.root))
    assert_receive {:commit_tailnet, _metadata}
  end

  test "configured gateways can change only Tailnet", context do
    machine = start_machine(context)
    accept_initial(machine)
    accepted_cluster = Configuration.current(machine)["cluster"]
    flush_messages()

    assert {:ok, pending} =
             Configuration.begin_change(:tailnet, "change-a", 60_000, machine)

    assert pending.phase == :tailnet
    assert pending.scope == :tailnet
    assert Configuration.diagnostics(machine).state == :needs_tailnet

    assert {:ok, pending} =
             Configuration.stage_tailnet(pending.id, tailnet_params(), machine)

    assert pending.phase == :confirmation
    assert pending.scope == :tailnet
    assert_receive {:stage_tailnet, "tskey-auth-candidate", "candidate-profile"}
    refute_receive {:cluster, _group}

    assert {:error, :configuration_change_outside_scope} =
             Configuration.stage_cluster(pending.id, cluster_params(), machine)

    assert :ok = Configuration.confirm(pending.id, connection("change-b"), machine)
    assert_receive {:commit_tailnet, _metadata}
    refute_receive {:cluster, _group}
    refute_receive {:subnet_router, _enabled, _routes}
    assert Configuration.current(machine)["cluster"] == accepted_cluster
  end

  test "configured gateways can change only their cluster group", context do
    machine = start_machine(context)
    accept_initial(machine)
    accepted_internet = Configuration.current(machine)["internet"]
    accepted_profile = Configuration.current(machine)["tailnet"]["profile_id"]
    flush_messages()

    assert {:ok, pending} =
             Configuration.begin_change(:cluster, "change-a", 60_000, machine)

    assert pending.phase == :cluster
    assert pending.scope == :cluster
    assert Configuration.diagnostics(machine).state == :needs_cluster

    assert {:error, :configuration_change_outside_scope} =
             Configuration.stage_tailnet(pending.id, tailnet_params(), machine)

    assert {:error, :configuration_change_outside_scope} =
             Configuration.update_internet(pending.id, internet_params(), machine)

    params = %{"cluster" => %{"group" => "New_group"}}
    assert {:ok, pending} = Configuration.stage_cluster(pending.id, params, machine)
    assert pending.phase == :confirmation
    assert_receive {:cluster, "New_group"}
    refute_receive {:stage_tailnet, _token, _previous}

    assert :ok = Configuration.confirm(pending.id, connection("change-b"), machine)
    refute_receive {:commit_tailnet, _metadata}
    refute_receive {:subnet_router, _enabled, _routes}
    assert Configuration.current(machine)["internet"] == accepted_internet
    assert Configuration.current(machine)["tailnet"]["profile_id"] == accepted_profile
  end

  test "a scoped revert restores only the selected subsystem", context do
    machine = start_machine(context)
    accept_initial(machine)
    flush_messages()

    assert {:ok, pending} =
             Configuration.begin_change(:cluster, "change-a", 60_000, machine)

    assert {:ok, pending} =
             Configuration.stage_cluster(
               pending.id,
               %{"cluster" => %{"group" => "New_group"}},
               machine
             )

    flush_messages()
    assert :ok = Configuration.revert(pending.id, machine)
    assert_receive {:cluster, "Field_group"}
    refute_receive {:internet_restore, _config}
    refute_receive {:rollback_tailnet, _metadata}
    refute_receive {:subnet_router, _enabled, _routes}
    refute_receive {:ssh, _enabled}
  end

  test "editing completed steps preserves later candidate work", context do
    machine = start_machine(context)

    {:ok, internet} =
      Configuration.stage_internet(internet_params(), "connection-a", nil, machine)

    {:ok, tailnet} = Configuration.stage_tailnet(internet.id, tailnet_params(), machine)

    updated = put_in(internet_params(), ["device", "name"], "Updated gateway")
    assert {:ok, pending} = Configuration.update_internet(tailnet.id, updated, machine)
    assert pending.phase == :cluster
    assert pending.candidate.name == "Updated gateway"
    assert pending.candidate.tailnet_configured
  end

  test "configured candidates time out through the ordinary revert transition", context do
    machine = start_machine(context)
    accept_initial(machine)
    accepted = settings(context.root, "a")

    {:ok, internet} = Configuration.stage_internet(internet_params(), "connection-a", 50, machine)
    {:ok, tailnet} = Configuration.stage_tailnet(internet.id, tailnet_params(), machine)
    {:ok, _pending} = Configuration.stage_cluster(tailnet.id, cluster_params(), machine)

    assert_eventually(fn -> Configuration.configuration(machine).pending == nil end)
    assert settings(context.root, "a") == accepted
    refute File.exists?(Persistence.candidate_path(context.root))
  end

  test "first commissioning has no automatic timeout", context do
    machine = start_machine(context)
    {:ok, pending} = Configuration.stage_internet(internet_params(), "connection-a", 20, machine)
    assert pending.remaining_seconds == nil
    Process.sleep(600)
    assert Configuration.configuration(machine).pending.id == pending.id
    assert :ok = Configuration.revert(pending.id, machine)
  end

  test "restart rejects and clears an unconfirmed candidate", context do
    machine = start_machine(context)
    {:ok, _pending} = stage_complete(machine)
    GenServer.stop(machine)
    assert File.exists?(Persistence.candidate_path(context.root))

    restarted = start_machine(context)
    assert Configuration.configuration(restarted).pending == nil
    refute File.exists?(Persistence.candidate_path(context.root))
    refute Configuration.configured?(restarted)
  end

  test "subnet desired state is durable before runtime reconciliation", context do
    owner = self()

    effect = fn _enabled, routes, _change_id ->
      {:ok, persisted} =
        Storage.read_json(Persistence.settings_path("a", context.root), &Settings.validate/1, nil)

      send(owner, {:effect_saw, persisted["subnet_router"]})
      {:ok, routes}
    end

    context = %{context | ops: Keyword.put(context.ops, :subnet_router, effect)}
    machine = start_machine(context)
    accept_initial(machine)

    assert {:ok, %{enabled: true}} =
             Configuration.configure_subnet_router(true, ["192.168.30.42/24"], machine)

    assert_receive {:effect_saw, %{"enabled" => true, "routes" => ["192.168.30.0/24"]}}
  end

  test "runtime dispatch failure does not roll back durable desired intent", context do
    effect = fn _enabled, _routes, _change_id -> {:error, :daemon} end
    context = %{context | ops: Keyword.put(context.ops, :subnet_router, effect)}
    machine = start_machine(context)
    accept_initial(machine)

    assert {:ok, %{enabled: true}} =
             Configuration.configure_subnet_router(true, ["192.168.40.0/24"], machine)

    assert Configuration.current(machine)["subnet_router"] == %{
             "enabled" => true,
             "routes" => ["192.168.40.0/24"]
           }

    assert Configuration.configuration(machine).last_error == :runtime_dispatch_failed
  end

  test "restart reapplies durable desired state without a resource-change saga", context do
    owner = self()

    effect = fn enabled, routes, change_id ->
      send(owner, {:runtime_change, enabled, routes, change_id})
      {:ok, routes}
    end

    context = %{context | ops: Keyword.put(context.ops, :subnet_router, effect)}
    machine = start_machine(context)
    accept_initial(machine)
    flush_messages()

    assert {:ok, %{enabled: true}} =
             Configuration.configure_subnet_router(true, ["10.40.0.0/16"], machine)

    assert_receive {:runtime_change, true, ["10.40.0.0/16"], change_id}
    assert is_binary(change_id)
    refute Map.has_key?(settings(context.root, "a"), "resource_changes")

    GenServer.stop(machine)

    recovering_effect = fn enabled, routes, recovered_id ->
      send(owner, {:recovered_runtime_change, enabled, routes, recovered_id})
      {:ok, routes}
    end

    context = %{context | ops: Keyword.put(context.ops, :subnet_router, recovering_effect)}
    restarted = start_machine(context)

    assert_receive {:recovered_runtime_change, true, ["10.40.0.0/16"], nil}
    assert_eventually(fn -> Configuration.diagnostics(restarted).state == :idle end)
  end

  test "candidate persistence failure never starts a configuration transaction", context do
    machine = start_machine(context)
    File.chmod!(context.root, 0o500)

    assert {:error, _reason} =
             Configuration.stage_internet(internet_params(), "connection-a", nil, machine)

    assert Configuration.diagnostics(machine).state == :idle
    assert Configuration.configuration(machine).pending == nil
  after
    File.chmod(context.root, 0o700)
  end

  test "noncritical settings cannot race an active guarded candidate", context do
    machine = start_machine(context)
    accept_initial(machine)

    {:ok, _pending} =
      Configuration.stage_internet(internet_params(), "connection-a", 60_000, machine)

    assert {:error, {:invalid_transition, :needs_tailnet, :configure_ssh}} =
             Configuration.configure_ssh(true, machine)

    assert {:error, {:invalid_transition, :needs_tailnet, :configure_subnet_router}} =
             Configuration.configure_subnet_router(true, ["192.168.10.0/24"], machine)
  end

  defp start_machine(context) do
    name = String.to_atom("configuration_machine_#{System.unique_integer([:positive])}")
    firmware = Map.get(context, :firmware, firmware("a", "firmware-a", "firmware-b"))

    payload =
      Configuration.new(
        root: context.root,
        firmware: fn -> firmware end,
        ops: context.ops,
        keep_local_access: false,
        publisher: fn _ -> :ok end
      )

    {:ok, machine} = Configuration.start_link(payload: payload, name: name)
    assert_eventually(fn -> Configuration.diagnostics(machine).state == :idle end)
    machine
  end

  defp accept_initial(machine) do
    {:ok, pending} = stage_complete(machine)
    :ok = Configuration.confirm(pending.id, connection("connection-b"), machine)
  end

  defp stage_complete(machine) do
    with {:ok, internet} <-
           Configuration.stage_internet(internet_params(), "connection-a", nil, machine),
         {:ok, tailnet} <- Configuration.stage_tailnet(internet.id, tailnet_params(), machine) do
      Configuration.stage_cluster(tailnet.id, cluster_params(), machine)
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
  defp connection(id), do: %{id: id, tailnet?: true}

  defp firmware(active, a_uuid, b_uuid) do
    %{active: active, slots: %{"a" => tag("a", a_uuid), "b" => tag("b", b_uuid)}}
  end

  defp tag(slot, uuid), do: %{"slot" => slot, "uuid" => uuid, "version" => "1.0.0"}

  defp settings(root, slot) do
    {:ok, value} =
      Storage.read_json(Persistence.settings_path(slot, root), &Settings.validate/1, nil)

    value
  end

  defp flush_messages do
    receive do
      _message -> flush_messages()
    after
      0 -> :ok
    end
  end

  defp assert_eventually(predicate, attempts \\ 150) do
    cond do
      predicate.() -> :ok
      attempts == 0 -> flunk("condition did not converge")
      true -> Process.sleep(10) && assert_eventually(predicate, attempts - 1)
    end
  end
end

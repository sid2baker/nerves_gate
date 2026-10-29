defmodule NervesGate.IOTest do
  use ExUnit.Case, async: false
  alias NervesGate.IO, as: GateIO
  alias NervesGate.Plugins.Owner
  alias NervesGateSDK.IO.{InputDefinition, OutputDefinition}
  import NervesGate.IOFixture

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    fixture = NervesGate.IOFixture.start()
    path = Path.join(dir, "io.term")
    controller = start_supervised!({GateIO, path: path})
    Map.merge(fixture, %{path: path, controller: controller})
  end

  test "definitions persist but registration, readings, claims and desire do not", %{
    path: path
  } do
    register_pair()
    assert {:ok, reading} = publish(21.0)
    assert reading.received_at_utc == nil
    assert :ok = GateIO.claim_output("io_fixture.setpoint")
    assert :ok = GateIO.set_output("io_fixture.setpoint", 22.0)
    assert {:ok, 22.0} = desired("setpoint")

    assert {:ok, %{desired: 22.0, status: %{state: :pending}}} =
             GateIO.output("io_fixture.setpoint")

    assert %{schema: 2, definitions: definitions} =
             path |> File.read!() |> :erlang.binary_to_term()

    assert definitions == GateIO.definitions()
    stop_supervised!(GateIO)
    start_supervised!({GateIO, path: path})
    assert {:ok, %{available?: false, reading: nil}} = GateIO.input("io_fixture.temperature")

    assert {:ok, %{available?: false, desired: nil, claimed?: false}} =
             GateIO.output("io_fixture.setpoint")

    assert {:error, :endpoint_unavailable} = GateIO.claim_output("io_fixture.setpoint")
    register_pair()
    assert {:ok, nil} = desired("setpoint")
    assert {:ok, %{reading: nil}} = GateIO.input("io_fixture.temperature")
    assert {:error, :invalid_output_write} = GateIO.set_output("io_fixture.setpoint", 22.0)
    refute_receive {:plugin_hint, _, {:nerves_gate_output, _, _}}
  end

  test "SDK bridge preserves actual registration, subscription, handler and writer PIDs" do
    sdk = NervesGateSDK.IO
    assert {:error, :plugin_not_running} = sdk.subscribe("io_fixture.temperature")
    assert {:error, :plugin_not_running} = sdk.claim_output("io_fixture.setpoint")

    assert {:ok, "io_fixture.temperature"} =
             plugin(Publisher, fn -> sdk.register_input(input_definition()) end)

    assert {:ok, "io_fixture.setpoint"} =
             plugin(Handler, fn ->
               NervesGateSDK.Backend.call(:io_register_output, [
                 %OutputDefinition{id: "setpoint", type: :float},
                 self()
               ])
             end)

    assert {:ok, controller} = plugin(Other, fn -> sdk.subscribe("io_fixture.temperature") end)
    assert controller == Process.whereis(GateIO)

    assert {:ok, reading} =
             plugin(Publisher, fn -> sdk.publish("temperature", 21.0) end)

    other = Process.whereis(Other)
    assert_receive {:plugin_hint, ^other, {:nerves_gate_input_changed, "io_fixture.temperature"}}

    assert {:ok, %{reading: ^reading}} =
             plugin(Other, fn -> sdk.input("io_fixture.temperature") end)

    assert :ok = plugin(Other, fn -> sdk.claim_output("io_fixture.setpoint") end)
    assert :ok = plugin(Other, fn -> sdk.set_output("io_fixture.setpoint", 22.0) end)
    assert {:ok, 22.0} = desired("setpoint")

    assert {:error, :invalid_output_write} =
             plugin(Publisher, fn -> sdk.set_output("io_fixture.setpoint", 23.0) end)

    assert :ok = plugin(Other, fn -> sdk.release_output("io_fixture.setpoint") end)
    assert {:ok, nil} = desired("setpoint")
    assert :ok = plugin(Other, fn -> sdk.unsubscribe("io_fixture.temperature") end)
  end

  test "registration derives namespace and checks both actual PIDs" do
    definition = input_definition()
    assert {:error, :plugin_not_running} = GateIO.register_input(definition)

    assert {:ok, "io_fixture.temperature"} =
             plugin(Publisher, fn -> GateIO.register_input(definition) end)

    assert {:ok, "io_fixture.temperature"} =
             plugin(Publisher, fn -> GateIO.register_input(definition) end)

    assert {:error, :endpoint_owned} = plugin(Other, fn -> GateIO.register_input(definition) end)

    assert {:error, :definition_conflict} =
             plugin(Publisher, fn -> GateIO.register_input(%{definition | unit: "kelvin"}) end)

    assert {:error, :definition_conflict} =
             plugin(Publisher, fn ->
               GateIO.register_output(%OutputDefinition{id: "temperature", type: :float}, self())
             end)

    parent = self()

    assert {:error, :invalid_registration} =
             plugin(Publisher, fn -> GateIO.register_output(output_definition(), parent) end)

    assert {:error, :invalid_publication} =
             plugin(Other, fn -> GateIO.publish("temperature", 10.0) end)
  end

  test "latest invalid/unknown samples replace good values and equal samples refresh time" do
    register_pair()
    assert {:ok, first} = publish(21.0)
    assert {:ok, second} = publish(21.0)
    assert second.received_at_ms >= first.received_at_ms
    assert {:error, :invalid_publication} = publish(21)

    assert {:error, :invalid_publication} =
             plugin(Publisher, fn -> GateIO.publish("temperature", 21.0, :invalid) end)

    for quality <- [:invalid, :unknown] do
      assert {:ok, %{value: nil, quality: ^quality}} =
               plugin(Publisher, fn -> GateIO.publish("temperature", nil, quality) end)

      assert {:ok, %{reading: %{value: nil, quality: ^quality}}} =
               GateIO.input("io_fixture.temperature")
    end
  end

  test "one outstanding hint per subscriber/input retains the final state without a later publication",
       %{controller: controller} do
    register_pair()
    assert {:ok, ^controller} = GateIO.subscribe("io_fixture.temperature")
    assert {:ok, %{reading: nil}} = GateIO.input("io_fixture.temperature")
    for value <- 1..10, do: publish(value * 1.0)
    assert_receive {:nerves_gate_input_changed, "io_fixture.temperature"}
    refute_receive {:nerves_gate_input_changed, _}
    assert {:ok, %{reading: %{value: 10.0}}} = GateIO.input("io_fixture.temperature")
    assert {:ok, _} = publish(11.0)
    assert_receive {:nerves_gate_input_changed, "io_fixture.temperature"}
    assert {:ok, %{reading: %{value: 11.0}}} = GateIO.input("io_fixture.temperature")
    assert :ok = GateIO.unsubscribe("io_fixture.temperature")
    publish(12.0)
    refute_receive {:nerves_gate_input_changed, _}
  end

  test "another reader cannot consume a subscriber's dirty state" do
    register_pair()
    plugin(Other, fn -> GateIO.subscribe("io_fixture.temperature") end)
    publish(1.0)
    other = Process.whereis(Other)
    assert_receive {:plugin_hint, ^other, {:nerves_gate_input_changed, "io_fixture.temperature"}}
    assert {:ok, _} = GateIO.input("io_fixture.temperature")
    publish(2.0)
    refute_receive {:plugin_hint, ^other, {:nerves_gate_input_changed, _}}

    assert {:ok, %{reading: %{value: 2.0}}} =
             plugin(Other, fn -> GateIO.input("io_fixture.temperature") end)

    publish(3.0)
    assert_receive {:plugin_hint, ^other, {:nerves_gate_input_changed, "io_fixture.temperature"}}
  end

  test "snapshot reads drain queued hints even when the consumer polls" do
    register_pair()
    GateIO.subscribe("io_fixture.temperature")

    for value <- 1..20 do
      publish(value * 1.0)
      assert {:ok, %{reading: %{value: observed}}} = GateIO.input("io_fixture.temperature")
      assert observed == value * 1.0
    end

    refute_receive {:nerves_gate_input_changed, _}
  end

  test "subscribe then read includes a change between those operations" do
    register_pair()
    GateIO.subscribe("io_fixture.temperature")
    publish(19.5)
    assert {:ok, %{reading: %{value: 19.5}}} = GateIO.input("io_fixture.temperature")
    publish(20.5)
    assert_receive {:nerves_gate_input_changed, "io_fixture.temperature"}
  end

  test "manual and automation-style writers cannot compete; only the handler reads desire" do
    register_pair()
    assert :ok = GateIO.claim_output("io_fixture.setpoint")

    assert {:error, :output_owned} =
             plugin(Other, fn -> GateIO.claim_output("io_fixture.setpoint") end)

    assert {:error, :invalid_output_write} =
             plugin(Other, fn -> GateIO.set_output("io_fixture.setpoint", 22.0) end)

    assert {:error, :not_output_owner} =
             plugin(Other, fn -> GateIO.release_output("io_fixture.setpoint") end)

    assert {:error, :not_output_handler} =
             plugin(Publisher, fn -> GateIO.read_desired("setpoint") end)

    assert {:ok, nil} = desired("setpoint")
    assert {:error, :invalid_output_write} = GateIO.set_output("io_fixture.setpoint", 22)
    assert {:error, :invalid_output_write} = GateIO.set_output("io_fixture.setpoint", 100.0)
    assert :ok = GateIO.set_output("io_fixture.setpoint", 22.0)

    assert {:ok, %{desired: 22.0, status: %{applied: nil}}} =
             GateIO.output("io_fixture.setpoint")

    assert :ok = GateIO.release_output("io_fixture.setpoint")
    assert {:ok, nil} = desired("setpoint")
    assert :ok = plugin(Other, fn -> GateIO.claim_output("io_fixture.setpoint") end)
  end

  test "output hints coalesce while a handler is busy; the final desired value remains readable" do
    register_pair()
    GateIO.claim_output("io_fixture.setpoint")
    handler = Process.whereis(Handler)
    # The claim's new epoch already hinted; reading clears it before the burst.
    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
    {:ok, nil} = desired("setpoint")
    :sys.suspend(handler)

    try do
      for value <- 1..10, do: assert(:ok = GateIO.set_output("io_fixture.setpoint", value * 1.0))
      assert {:ok, %{desired: 10.0}} = GateIO.output("io_fixture.setpoint")
      assert {:message_queue_len, 1} = Process.info(handler, :message_queue_len)
    after
      :sys.resume(handler)
    end

    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
    assert {:ok, 10.0} = desired("setpoint")
    GateIO.set_output("io_fixture.setpoint", 11.0)
    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
  end

  test "false is an active desired value, not an absent value" do
    plugin(Handler, fn ->
      GateIO.register_output(%OutputDefinition{id: "enable", type: :boolean}, self())
    end)

    GateIO.claim_output("io_fixture.enable")
    assert :ok = GateIO.set_output("io_fixture.enable", false)
    assert {:ok, false} = desired("enable")
    GateIO.release_output("io_fixture.enable")
    assert {:ok, nil} = desired("enable")
  end

  test "writer death clears desire, releases ownership and wakes the handler without a device command" do
    register_pair()

    plugin(Other, fn ->
      :ok = GateIO.claim_output("io_fixture.setpoint")
      GateIO.set_output("io_fixture.setpoint", 22.0)
    end)

    assert {:ok, 22.0} = desired("setpoint")
    handler = Process.whereis(Handler)
    flush_plugin_hints()
    Supervisor.terminate_child(FixtureSupervisor, Other)
    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
    assert {:ok, nil} = desired("setpoint")
    assert {:ok, %{claimed?: false, desired: nil}} = GateIO.output("io_fixture.setpoint")
    assert :ok = GateIO.claim_output("io_fixture.setpoint")
  end

  test "handler or registering owner loss invalidates the output and never transfers desire" do
    register_pair()
    GateIO.claim_output("io_fixture.setpoint")
    GateIO.set_output("io_fixture.setpoint", 22.0)
    Supervisor.terminate_child(FixtureSupervisor, Handler)

    assert {:ok, %{available?: false, claimed?: false, desired: nil}} =
             GateIO.output("io_fixture.setpoint")

    {:ok, _} = Supervisor.restart_child(FixtureSupervisor, Handler)
    register_pair()
    assert {:ok, nil} = desired("setpoint")
    assert {:error, :invalid_output_write} = GateIO.set_output("io_fixture.setpoint", 22.0)
    Supervisor.terminate_child(FixtureSupervisor, Publisher)
    assert {:ok, %{available?: false}} = GateIO.output("io_fixture.setpoint")
  end

  test "quiescing accepts reads and feedback but fences registration and desire", %{owner: owner} do
    register_pair()
    GateIO.claim_output("io_fixture.setpoint")
    GateIO.set_output("io_fixture.setpoint", 22.0)
    Owner.quiesce(owner)
    assert {:ok, _} = publish(20.0)
    assert {:ok, 22.0} = desired("setpoint")

    assert {:error, :plugin_not_running} =
             plugin(Publisher, fn -> GateIO.register_input(input_definition()) end)

    assert {:error, :endpoint_unavailable} = GateIO.set_output("io_fixture.setpoint", 23.0)
    assert {:error, :endpoint_unavailable} = GateIO.claim_output("io_fixture.setpoint")
    assert :ok = GateIO.release_output("io_fixture.setpoint")
  end

  test "generation revocation invalidates snapshots and new bindings need fresh ownership", %{
    owner: owner,
    artifact: artifact
  } do
    register_pair()
    GateIO.subscribe("io_fixture.temperature")
    publish(20.0)
    GateIO.input("io_fixture.temperature")
    GateIO.claim_output("io_fixture.setpoint")
    GateIO.set_output("io_fixture.setpoint", 22.0)
    Owner.revoke(owner)
    assert {:ok, %{available?: false, reading: nil}} = GateIO.input("io_fixture.temperature")
    assert {:error, :endpoint_unavailable} = publish(21.0)

    assert {:error, :plugin_not_running} =
             desired("setpoint")

    assert {:ok, %{desired: nil, claimed?: false}} = GateIO.output("io_fixture.setpoint")
    Application.stop(:io_fixture)
    Owner.bind(artifact, {make_ref(), 2})
    Application.start(:io_fixture)
    register_pair()
    assert {:ok, nil} = desired("setpoint")
    assert {:error, :invalid_output_write} = GateIO.set_output("io_fixture.setpoint", 22.0)
  end

  test "subscriber death removes subscription and controller loss requires fresh subscription", %{
    path: path,
    controller: controller
  } do
    register_pair()
    plugin(Other, fn -> GateIO.subscribe("io_fixture.temperature") end)
    other = Process.whereis(Other)
    Supervisor.terminate_child(FixtureSupervisor, Other)
    publish(20.0)
    refute Map.has_key?(:sys.get_state(controller).subscribers, other)
    {:ok, ^controller} = GateIO.subscribe("io_fixture.temperature")
    ref = Process.monitor(controller)
    stop_supervised!(GateIO)
    assert_receive {:DOWN, ^ref, :process, ^controller, _}
    next = start_supervised!({GateIO, path: path})
    register_pair()
    publish(21.0)
    refute_receive {:nerves_gate_input_changed, _}
    assert {:ok, ^next} = GateIO.subscribe("io_fixture.temperature")
    GateIO.input("io_fixture.temperature")
    publish(22.0)
    assert_receive {:nerves_gate_input_changed, "io_fixture.temperature"}
  end

  test "a definition persistence failure never registers and blocks further catalog writes", %{
    path: path
  } do
    File.mkdir_p!(path)

    assert {:error, :io_catalog_write_failed} =
             plugin(Publisher, fn -> GateIO.register_input(input_definition()) end)

    assert GateIO.definitions() == %{}
    File.rmdir!(path)

    assert {:error, :io_catalog_write_failed} =
             plugin(Publisher, fn -> GateIO.register_input(input_definition()) end)

    refute File.exists?(path)
  end

  test "quiescing alone eventually notifies input subscribers without another publication", %{
    owner: owner
  } do
    register_pair()
    GateIO.subscribe("io_fixture.temperature")
    GateIO.input("io_fixture.temperature")
    Owner.quiesce(owner)
    assert_receive {:nerves_gate_input_changed, "io_fixture.temperature"}, 1_500
    assert {:ok, %{available?: false}} = GateIO.input("io_fixture.temperature")
    refute_receive {:nerves_gate_input_changed, _}
  end

  test "managed consumers lose ownership on quiesce and subscriptions on revocation", %{
    owner: owner
  } do
    register_pair()
    sdk = NervesGateSDK.IO
    assert {:ok, _} = plugin(Other, fn -> sdk.subscribe("io_fixture.temperature") end)
    assert :ok = plugin(Other, fn -> sdk.claim_output("io_fixture.setpoint") end)
    assert :ok = plugin(Other, fn -> sdk.set_output("io_fixture.setpoint", 22.0) end)
    Owner.quiesce(owner)
    assert {:ok, %{desired: nil, claimed?: false}} = GateIO.output("io_fixture.setpoint")
    assert {:ok, nil} = desired("setpoint")
    Owner.revoke(owner)
    GateIO.input("io_fixture.temperature")
    refute Map.has_key?(:sys.get_state(GateIO).subscribers, Process.whereis(Other))
  end

  test "revocation alone eventually clears desire and notifies readers", %{owner: owner} do
    register_pair()
    GateIO.subscribe("io_fixture.temperature")
    GateIO.input("io_fixture.temperature")
    GateIO.claim_output("io_fixture.setpoint")
    GateIO.set_output("io_fixture.setpoint", 22.0)
    desired("setpoint")
    flush_plugin_hints()
    Owner.revoke(owner)
    assert_receive {:nerves_gate_input_changed, "io_fixture.temperature"}, 1_500
    assert {:ok, %{desired: nil, claimed?: false}} = GateIO.output("io_fixture.setpoint")

    assert {:error, :plugin_not_running} =
             desired("setpoint")
  end

  test "unsupported saved definitions disable I/O without stopping it or rewriting them", %{
    path: path
  } do
    stop_supervised!(GateIO)

    for bytes <- [
          "not an I/O catalog",
          :erlang.term_to_binary(%{schema: 1, definitions: %{}})
        ] do
      File.write!(path, bytes)
      controller = start_supervised!({GateIO, path: path})
      assert {:error, :io_catalog_unavailable} = GateIO.snapshot()
      assert {:error, :io_catalog_unavailable} = GateIO.claim_output("io_fixture.setpoint")

      assert {:error, :io_catalog_unavailable} =
               plugin(Publisher, fn -> GateIO.register_input(input_definition()) end)

      assert File.read!(path) == bytes
      assert Process.alive?(controller)
      stop_supervised!(GateIO)
    end
  end

  test "each claim starts a new epoch; reports for ended epochs or superseded Desires are rejected" do
    register_pair()
    assert {:ok, %{desired: nil, epoch: nil}} = read("setpoint")
    :ok = GateIO.claim_output("io_fixture.setpoint")
    {:ok, %{desired: nil, epoch: first}} = read("setpoint")
    assert is_integer(first)
    :ok = GateIO.claim_output("io_fixture.setpoint")
    assert {:ok, %{epoch: ^first}} = read("setpoint")
    :ok = GateIO.set_output("io_fixture.setpoint", 22.0)

    assert {:error, :not_output_handler} =
             plugin(Publisher, fn -> GateIO.report_applied("setpoint", first, 22.0, :applied) end)

    assert {:error, :invalid_outcome} = report(first, 22.0, :done)
    assert {:error, :stale_report} = report(first, 21.0, :applied)
    assert :ok = report(first, 22.0, :applied)

    # An equal Desire under a new claim is a new epoch; the earlier report no longer counts.
    :ok = GateIO.release_output("io_fixture.setpoint")
    assert {:error, :stale_report} = report(first, 22.0, :applied)
    :ok = plugin(Other, fn -> GateIO.claim_output("io_fixture.setpoint") end)
    :ok = plugin(Other, fn -> GateIO.set_output("io_fixture.setpoint", 22.0) end)
    {:ok, %{desired: 22.0, epoch: second}} = read("setpoint")
    assert second > first
    assert {:error, :stale_report} = report(first, 22.0, :applied)
    assert {:ok, %{status: %{applied: nil}}} = GateIO.output("io_fixture.setpoint")
    assert :ok = report(second, 22.0, {:failed, :timeout})

    assert {:ok, %{status: %{state: :mismatch, applied: :failed}}} =
             GateIO.output("io_fixture.setpoint")
  end

  test "Status uses only readings received after the Desire changed" do
    register_pair()
    :ok = GateIO.claim_output("io_fixture.setpoint")
    {:ok, _} = publish(22.0)
    :ok = GateIO.set_output("io_fixture.setpoint", 22.0)
    {:ok, %{epoch: epoch}} = read("setpoint")
    :ok = report(epoch, 22.0, :applied)

    # The earlier equal Reading cannot confirm the new Desire.
    assert {:ok, %{status: %{state: :pending, evidence: [%{state: :pending}]}}} =
             GateIO.output("io_fixture.setpoint")

    Process.sleep(2)
    {:ok, _} = publish(22.3)

    assert {:ok, %{status: %{state: :confirmed, applied: :applied}}} =
             GateIO.output("io_fixture.setpoint")

    {:ok, _} = publish(25.0)

    assert {:ok, %{status: %{state: :mismatch, evidence: [%{state: :contradicted}]}}} =
             GateIO.output("io_fixture.setpoint")

    # An unchanged Desire keeps its change time; a new value restarts settling.
    :ok = GateIO.set_output("io_fixture.setpoint", 22.0)
    assert {:ok, %{status: %{state: :mismatch}}} = GateIO.output("io_fixture.setpoint")
    :ok = GateIO.set_output("io_fixture.setpoint", 25.0)
    assert {:ok, %{status: %{state: :pending}}} = GateIO.output("io_fixture.setpoint")

    # An uncertain Apply followed by matching readback is confirmed: evidence wins.
    {:ok, %{epoch: ^epoch}} = read("setpoint")
    :ok = report(epoch, 25.0, :unknown)
    Process.sleep(2)
    {:ok, _} = publish(25.0)

    assert {:ok, %{status: %{state: :confirmed, applied: :unknown}}} =
             GateIO.output("io_fixture.setpoint")
  end

  test "evidence registered later or with an incompatible type never fabricates Status" do
    handler = Process.whereis(Handler)

    assert {:ok, "io_fixture.setpoint"} =
             plugin(Publisher, fn -> GateIO.register_output(output_definition(), handler) end)

    :ok = GateIO.claim_output("io_fixture.setpoint")
    :ok = GateIO.set_output("io_fixture.setpoint", 20.0)

    assert {:ok, %{status: %{evidence: [%{state: :unknown}]}}} =
             GateIO.output("io_fixture.setpoint")

    plugin(Publisher, fn ->
      GateIO.register_input(%InputDefinition{id: "temperature", type: :string})
    end)

    plugin(Publisher, fn -> GateIO.publish("temperature", "20") end)

    assert {:ok, %{status: %{state: :pending, evidence: [%{state: :unknown}]}}} =
             GateIO.output("io_fixture.setpoint")
  end

  test "snapshot lists every endpoint, reveals ownership only to its writer and consumes no hints" do
    register_pair()
    {:ok, _} = plugin(Other, fn -> GateIO.subscribe("io_fixture.temperature") end)
    {:ok, reading} = publish(21.5)
    other = Process.whereis(Other)
    assert_receive {:plugin_hint, ^other, {:nerves_gate_input_changed, "io_fixture.temperature"}}

    assert %{
             inputs: [%{id: "io_fixture.temperature", reading: ^reading, stale?: false}],
             outputs: [
               %{id: "io_fixture.setpoint", claimed?: false, owned?: false, desired: nil}
             ]
           } = plugin(Other, &GateIO.snapshot/0)

    # The subscriber's hint is still outstanding: a further change sends no second hint.
    publish(21.6)
    refute_receive {:plugin_hint, ^other, {:nerves_gate_input_changed, _}}, 50

    :ok = GateIO.claim_output("io_fixture.setpoint")
    assert %{outputs: [%{claimed?: true, owned?: true}]} = GateIO.snapshot()
    assert %{outputs: [%{claimed?: true, owned?: false}]} = plugin(Other, &GateIO.snapshot/0)
    assert {:ok, %{owned?: false}} = plugin(Other, fn -> GateIO.output("io_fixture.setpoint") end)
  end

  test "manual control shares exclusive admission and owns claims independently of its callers" do
    alias NervesGate.IO.Manual
    start_supervised!(Manual)
    register_pair()
    id = "io_fixture.setpoint"
    handler = Process.whereis(Handler)

    assert {:error, %{code: "io_not_manual"}} = Manual.set(id, 22.0)
    assert {:error, %{code: "io_unknown_output"}} = Manual.claim("io_fixture.missing")

    # An automation-style writer holds the output: manual control cannot take or touch it.
    :ok = plugin(Other, fn -> GateIO.claim_output(id) end)
    assert {:error, %{code: "io_output_owned"}} = Manual.claim(id)
    assert {:error, %{code: "io_not_manual"}} = Manual.set(id, 22.0)
    assert {:error, %{code: "io_not_manual"}} = Manual.release(id)
    assert %{outputs: [%{claimed?: true, owned?: false}]} = Manual.status()
    :ok = plugin(Other, fn -> GateIO.release_output(id) end)

    assert :ok = Manual.claim(id)
    assert {:error, :output_owned} = plugin(Other, fn -> GateIO.claim_output(id) end)
    assert %{outputs: [%{owned?: true, desired: nil}]} = Manual.status()
    assert {:error, %{code: "io_invalid_value"}} = Manual.set(id, 100.0)
    assert {:error, %{code: "io_invalid_value"}} = Manual.set(id, 22)

    # The claim belongs to Manual, not to the (short-lived) caller. The handler's read
    # clears its outstanding hint, so the next change sends a fresh one.
    {:ok, nil} = desired("setpoint")
    flush_plugin_hints()
    assert :ok = Task.async(fn -> Manual.set(id, 22.0) end) |> Task.await()
    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
    assert {:ok, 22.0} = desired("setpoint")
    assert %{outputs: [%{owned?: true, desired: 22.0}]} = Manual.status()

    assert :ok = Manual.release(id)
    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
    assert {:ok, nil} = desired("setpoint")

    # Binding loss clears manual ownership and desire like any other writer's.
    :ok = Manual.claim(id)
    :ok = Manual.set(id, 22.0)
    Supervisor.terminate_child(FixtureSupervisor, Handler)

    assert %{outputs: [%{available?: false, claimed?: false, owned?: false, desired: nil}]} =
             Manual.status()

    assert {:error, %{code: "io_not_manual"}} = Manual.release(id)
    assert {:error, %{code: "io_output_unavailable"}} = Manual.claim(id)
  end

  test "manual control survives an unavailable I/O controller", %{controller: controller} do
    alias NervesGate.IO.Manual
    manual = start_supervised!(Manual)
    register_pair()
    :sys.suspend(controller)

    try do
      assert {:error, %{code: "outcome_unknown"}} = Manual.claim("io_fixture.setpoint")
    after
      :sys.resume(controller)
    end

    stop_supervised!(GateIO)
    assert {:error, %{code: "unavailable"}} = Manual.status()
    assert Process.alive?(manual)
  end

  # Handler reads and reports run through the SDK transport in the handler's own PID.
  defp read(local_id),
    do: plugin(Handler, fn -> NervesGateSDK.Backend.call(:io_read_desired, [local_id]) end)

  defp desired(local_id) do
    case read(local_id) do
      {:ok, %{desired: value}} -> {:ok, value}
      error -> error
    end
  end

  defp report(epoch, value, outcome) do
    plugin(Handler, fn ->
      NervesGateSDK.Backend.call(:io_report_applied, ["setpoint", epoch, value, outcome])
    end)
  end

  defp flush_plugin_hints do
    receive do
      {:plugin_hint, _, _} -> flush_plugin_hints()
    after
      0 -> :ok
    end
  end
end

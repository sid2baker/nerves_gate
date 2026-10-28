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

  test "definitions persist but registration, observations, claims and desire do not", %{
    path: path
  } do
    register_pair()
    assert {:ok, observation} = publish(21.0)
    assert observation.received_at_utc == nil
    assert :ok = GateIO.claim_output("io_fixture.setpoint")
    assert :ok = GateIO.set_output("io_fixture.setpoint", 22.0)
    assert {:ok, 22.0} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)

    assert {:ok, %{desired: 22.0, reported: %{observation: ^observation}}} =
             GateIO.output("io_fixture.setpoint")

    assert %{schema: 1, definitions: definitions} =
             path |> File.read!() |> :erlang.binary_to_term()

    assert definitions == GateIO.definitions()
    stop_supervised!(GateIO)
    start_supervised!({GateIO, path: path})
    assert {:ok, %{available?: false, observation: nil}} = GateIO.input("io_fixture.temperature")

    assert {:ok, %{available?: false, desired: nil, claimed?: false}} =
             GateIO.output("io_fixture.setpoint")

    assert {:error, :endpoint_unavailable} = GateIO.claim_output("io_fixture.setpoint")
    register_pair()
    assert {:ok, nil} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
    assert {:ok, %{observation: nil}} = GateIO.input("io_fixture.temperature")
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
               sdk.register_output(
                 %OutputDefinition{id: "setpoint", type: :float},
                 self()
               )
             end)

    assert {:ok, controller} = plugin(Other, fn -> sdk.subscribe("io_fixture.temperature") end)
    assert controller == Process.whereis(GateIO)

    assert {:ok, observation} =
             plugin(Publisher, fn -> sdk.publish_input("temperature", 21.0) end)

    other = Process.whereis(Other)
    assert_receive {:plugin_hint, ^other, {:nerves_gate_input_changed, "io_fixture.temperature"}}

    assert {:ok, %{observation: ^observation}} =
             plugin(Other, fn -> sdk.input("io_fixture.temperature") end)

    assert :ok = plugin(Other, fn -> sdk.claim_output("io_fixture.setpoint") end)
    assert :ok = plugin(Other, fn -> sdk.set_output("io_fixture.setpoint", 22.0) end)
    assert {:ok, 22.0} = plugin(Handler, fn -> sdk.read_desired("setpoint") end)

    assert {:error, :invalid_output_write} =
             plugin(Publisher, fn -> sdk.set_output("io_fixture.setpoint", 23.0) end)

    assert :ok = plugin(Other, fn -> sdk.release_output("io_fixture.setpoint") end)
    assert {:ok, nil} = plugin(Handler, fn -> sdk.read_desired("setpoint") end)
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
             plugin(Other, fn -> GateIO.publish_input("temperature", 10.0) end)
  end

  test "latest invalid/unknown samples replace good values and equal samples refresh time" do
    register_pair()
    assert {:ok, first} = publish(21.0)
    assert {:ok, second} = publish(21.0)
    assert second.received_at_ms >= first.received_at_ms
    assert {:error, :invalid_publication} = publish(21)

    assert {:error, :invalid_publication} =
             plugin(Publisher, fn -> GateIO.publish_input("temperature", 21.0, :invalid) end)

    for quality <- [:invalid, :unknown] do
      assert {:ok, %{value: nil, quality: ^quality}} =
               plugin(Publisher, fn -> GateIO.publish_input("temperature", nil, quality) end)

      assert {:ok, %{observation: %{value: nil, quality: ^quality}}} =
               GateIO.input("io_fixture.temperature")
    end
  end

  test "one outstanding hint per subscriber/input retains the final state without a later publication",
       %{controller: controller} do
    register_pair()
    assert {:ok, ^controller} = GateIO.subscribe("io_fixture.temperature")
    assert {:ok, %{observation: nil}} = GateIO.input("io_fixture.temperature")
    for value <- 1..10, do: publish(value * 1.0)
    assert_receive {:nerves_gate_input_changed, "io_fixture.temperature"}
    refute_receive {:nerves_gate_input_changed, _}
    assert {:ok, %{observation: %{value: 10.0}}} = GateIO.input("io_fixture.temperature")
    assert {:ok, _} = publish(11.0)
    assert_receive {:nerves_gate_input_changed, "io_fixture.temperature"}
    assert {:ok, %{observation: %{value: 11.0}}} = GateIO.input("io_fixture.temperature")
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

    assert {:ok, %{observation: %{value: 2.0}}} =
             plugin(Other, fn -> GateIO.input("io_fixture.temperature") end)

    publish(3.0)
    assert_receive {:plugin_hint, ^other, {:nerves_gate_input_changed, "io_fixture.temperature"}}
  end

  test "snapshot reads drain queued hints even when the consumer polls" do
    register_pair()
    GateIO.subscribe("io_fixture.temperature")

    for value <- 1..20 do
      publish(value * 1.0)
      assert {:ok, %{observation: %{value: observed}}} = GateIO.input("io_fixture.temperature")
      assert observed == value * 1.0
    end

    refute_receive {:nerves_gate_input_changed, _}
  end

  test "subscribe then read includes a change between those operations" do
    register_pair()
    GateIO.subscribe("io_fixture.temperature")
    publish(19.5)
    assert {:ok, %{observation: %{value: 19.5}}} = GateIO.input("io_fixture.temperature")
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

    assert {:ok, nil} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
    assert {:error, :invalid_output_write} = GateIO.set_output("io_fixture.setpoint", 22)
    assert {:error, :invalid_output_write} = GateIO.set_output("io_fixture.setpoint", 100.0)
    assert :ok = GateIO.set_output("io_fixture.setpoint", 22.0)

    assert {:ok, %{desired: 22.0, reported: %{observation: nil}}} =
             GateIO.output("io_fixture.setpoint")

    assert :ok = GateIO.release_output("io_fixture.setpoint")
    assert {:ok, nil} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
    assert :ok = plugin(Other, fn -> GateIO.claim_output("io_fixture.setpoint") end)
  end

  test "output hints coalesce while a handler is busy; the final desired value remains readable" do
    register_pair()
    GateIO.claim_output("io_fixture.setpoint")
    handler = Process.whereis(Handler)
    :sys.suspend(handler)

    try do
      for value <- 1..10, do: assert(:ok = GateIO.set_output("io_fixture.setpoint", value * 1.0))
      assert {:ok, %{desired: 10.0}} = GateIO.output("io_fixture.setpoint")
      assert {:message_queue_len, 1} = Process.info(handler, :message_queue_len)
    after
      :sys.resume(handler)
    end

    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
    assert {:ok, 10.0} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
    GateIO.set_output("io_fixture.setpoint", 11.0)
    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
  end

  test "false is an active desired value, not an absent value" do
    plugin(Handler, fn ->
      GateIO.register_output(%OutputDefinition{id: "enable", type: :boolean}, self())
    end)

    GateIO.claim_output("io_fixture.enable")
    assert :ok = GateIO.set_output("io_fixture.enable", false)
    assert {:ok, false} = plugin(Handler, fn -> GateIO.read_desired("enable") end)
    GateIO.release_output("io_fixture.enable")
    assert {:ok, nil} = plugin(Handler, fn -> GateIO.read_desired("enable") end)
  end

  test "writer death clears desire, releases ownership and wakes the handler without a device command" do
    register_pair()

    plugin(Other, fn ->
      :ok = GateIO.claim_output("io_fixture.setpoint")
      GateIO.set_output("io_fixture.setpoint", 22.0)
    end)

    assert {:ok, 22.0} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
    handler = Process.whereis(Handler)
    flush_plugin_hints()
    Supervisor.terminate_child(FixtureSupervisor, Other)
    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
    assert {:ok, nil} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
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
    assert {:ok, nil} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
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
    assert {:ok, 22.0} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)

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
    assert {:ok, %{available?: false, observation: nil}} = GateIO.input("io_fixture.temperature")
    assert {:error, :endpoint_unavailable} = publish(21.0)

    assert {:error, :endpoint_unavailable} =
             plugin(Handler, fn -> GateIO.read_desired("setpoint") end)

    assert {:ok, %{desired: nil, claimed?: false}} = GateIO.output("io_fixture.setpoint")
    Application.stop(:io_fixture)
    Owner.bind(artifact, {make_ref(), 2})
    Application.start(:io_fixture)
    register_pair()
    assert {:ok, nil} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
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
    assert {:ok, nil} = plugin(Handler, fn -> sdk.read_desired("setpoint") end)
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
    plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
    flush_plugin_hints()
    Owner.revoke(owner)
    assert_receive {:nerves_gate_input_changed, "io_fixture.temperature"}, 1_500
    assert {:ok, %{desired: nil, claimed?: false}} = GateIO.output("io_fixture.setpoint")

    assert {:error, :endpoint_unavailable} =
             plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
  end

  test "corrupt persisted definitions prevent controller startup without rewriting", %{path: path} do
    stop_supervised!(GateIO)
    bytes = "not an I/O catalog"
    File.write!(path, bytes)
    assert {:error, _} = start_supervised({GateIO, path: path})
    assert File.read!(path) == bytes
    refute Process.whereis(GateIO)
  end

  test "feedback registration order and incompatible feedback never fabricate observations" do
    handler = Process.whereis(Handler)

    assert {:ok, "io_fixture.setpoint"} =
             plugin(Publisher, fn -> GateIO.register_output(output_definition(), handler) end)

    assert {:ok, %{reported: nil}} = GateIO.output("io_fixture.setpoint")

    plugin(Publisher, fn ->
      GateIO.register_input(%InputDefinition{id: "temperature", type: :integer})
    end)

    plugin(Publisher, fn -> GateIO.publish_input("temperature", 20) end)
    assert {:ok, %{reported: nil}} = GateIO.output("io_fixture.setpoint")
  end

  test "snapshot lists every endpoint, reveals ownership only to its writer and consumes no hints" do
    register_pair()
    {:ok, _} = plugin(Other, fn -> GateIO.subscribe("io_fixture.temperature") end)
    {:ok, observation} = publish(21.5)
    other = Process.whereis(Other)
    assert_receive {:plugin_hint, ^other, {:nerves_gate_input_changed, "io_fixture.temperature"}}

    assert %{
             inputs: [%{id: "io_fixture.temperature", observation: ^observation, stale?: false}],
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
    {:ok, nil} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
    flush_plugin_hints()
    assert :ok = Task.async(fn -> Manual.set(id, 22.0) end) |> Task.await()
    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
    assert {:ok, 22.0} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)
    assert %{outputs: [%{owned?: true, desired: 22.0}]} = Manual.status()

    assert :ok = Manual.release(id)
    assert_receive {:plugin_hint, ^handler, {:nerves_gate_output_changed, "setpoint"}}
    assert {:ok, nil} = plugin(Handler, fn -> GateIO.read_desired("setpoint") end)

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

  defp flush_plugin_hints do
    receive do
      {:plugin_hint, _, _} -> flush_plugin_hints()
    after
      0 -> :ok
    end
  end
end

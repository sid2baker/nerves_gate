defmodule NervesGate.IOOutputRuntimeTest do
  use ExUnit.Case, async: false
  alias NervesGate.IO, as: GateIO
  alias NervesGateSDK.IO.OutputDefinition
  alias NervesGateSDK.Output
  import NervesGate.IOFixture

  # Each apply/3 call reports to the test and waits for the outcome it should return.
  defmodule Recorder do
    @behaviour NervesGateSDK.Output

    @impl true
    def apply(id, desired, parent) do
      send(parent, {:apply, self(), id, desired})

      receive do
        {:outcome, outcome} -> {outcome, parent}
      after
        5_000 -> {:unknown, parent}
      end
    end
  end

  @moduletag :tmp_dir
  setup %{tmp_dir: dir} do
    fixture = NervesGate.IOFixture.start()
    path = Path.join(dir, "io.term")
    start_supervised!({GateIO, path: path})
    parent = self()
    definition = %OutputDefinition{id: "relay", type: :boolean, on_release: :hold}

    # The runtime is started inside the plugin activation, by a process that traps
    # its exit the way a plugin's owning process would.
    {:ok, runtime} =
      plugin(Other, fn ->
        Process.flag(:trap_exit, true)
        Output.start_link(Recorder, [definition], parent)
      end)

    Map.merge(fixture, %{path: path, runtime: runtime, id: "io_fixture.relay"})
  end

  test "registration applies nothing; a Desire is applied once and its outcome recorded", %{
    id: id,
    runtime: runtime
  } do
    assert {:ok, %{available?: true, desired: nil}} = GateIO.output(id)
    :ok = GateIO.claim_output(id)
    refute_receive {:apply, _, _, _}, 100

    :ok = GateIO.set_output(id, true)
    assert_receive {:apply, ^runtime, "relay", true}
    send(runtime, {:outcome, :applied})
    await_applied(id, :applied)

    assert {:ok, %{status: %{state: :unknown, reason: "Applied; no evidence declared"}}} =
             GateIO.output(id)

    :ok = GateIO.set_output(id, true)
    refute_receive {:apply, _, _, _}, 100
  end

  test "the newest Desire wins and a superseded outcome is discarded", %{
    id: id,
    runtime: runtime
  } do
    :ok = GateIO.claim_output(id)
    :ok = GateIO.set_output(id, true)
    assert_receive {:apply, ^runtime, "relay", true}

    # While the first apply is in progress, the Desire changes twice.
    :ok = GateIO.set_output(id, false)
    :ok = GateIO.set_output(id, true)
    :ok = GateIO.set_output(id, false)
    send(runtime, {:outcome, :applied})

    assert_receive {:apply, ^runtime, "relay", false}
    refute_receive {:apply, _, _, true}, 100
    assert {:ok, %{status: %{applied: nil}}} = GateIO.output(id)
    send(runtime, {:outcome, {:failed, :busy}})
    await_applied(id, :failed)
  end

  test "release applies nil once; a new claim with an equal value is applied again", %{
    id: id,
    runtime: runtime
  } do
    :ok = GateIO.claim_output(id)
    :ok = GateIO.set_output(id, true)
    assert_receive {:apply, ^runtime, "relay", true}
    send(runtime, {:outcome, :applied})
    await_applied(id, :applied)

    :ok = GateIO.release_output(id)
    assert_receive {:apply, ^runtime, "relay", nil}
    send(runtime, {:outcome, :applied})

    :ok = plugin(Publisher, fn -> GateIO.claim_output(id) end)
    refute_receive {:apply, _, _, _}, 100
    :ok = plugin(Publisher, fn -> GateIO.set_output(id, true) end)
    assert_receive {:apply, ^runtime, "relay", true}
    send(runtime, {:outcome, :unknown})
    await_applied(id, :unknown)

    :ok = plugin(Publisher, fn -> GateIO.release_output(id) end)
    assert_receive {:apply, ^runtime, "relay", nil}
    send(runtime, {:outcome, :applied})
    :ok = GateIO.claim_output(id)
    :ok = GateIO.release_output(id)
    refute_receive {:apply, _, _, _}, 100
  end

  test "reapply applies the current Desire again", %{id: id, runtime: runtime} do
    :ok = GateIO.claim_output(id)
    :ok = GateIO.set_output(id, false)
    assert_receive {:apply, ^runtime, "relay", false}
    send(runtime, {:outcome, {:failed, :timeout}})
    Output.reapply(runtime, "relay")
    assert_receive {:apply, ^runtime, "relay", false}
    send(runtime, {:outcome, :applied})
    await_applied(id, :applied)
  end

  test "the runtime stops when the controller no longer accepts its handler", %{
    path: path,
    runtime: runtime
  } do
    ref = Process.monitor(runtime)
    stop_supervised!(GateIO)
    start_supervised!({GateIO, path: path})
    Output.reapply(runtime, "relay")

    assert_receive {:DOWN, ^ref, :process, ^runtime,
                    {:shutdown, {:output_unavailable, "relay", _}}}

    refute_received {:apply, _, _, _}
  end

  defp await_applied(id, summary, attempts \\ 50) do
    case GateIO.output(id) do
      {:ok, %{status: %{applied: ^summary}}} ->
        :ok

      _ when attempts > 0 ->
        Process.sleep(10)
        await_applied(id, summary, attempts - 1)

      other ->
        flunk("Apply outcome #{inspect(summary)} not recorded: #{inspect(other)}")
    end
  end
end

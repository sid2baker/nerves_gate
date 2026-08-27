defmodule NervesGate.FSM.EffectTest do
  use ExUnit.Case, async: true

  alias NervesGate.FSM.Effect

  setup do
    suffix = System.unique_integer([:positive])
    name = String.to_atom("effect_tasks_#{suffix}")
    registry = String.to_atom("effect_registry_#{suffix}")
    start_supervised!({Registry, keys: :unique, name: registry})
    start_supervised!({Task.Supervisor, name: name})
    %{supervisor: name, registry: registry}
  end

  test "a successful worker produces one correlated terminal event", context do
    ref = make_ref()

    assert {:ok, _coordinator} =
             Effect.start(self(), ref, fn -> {:ok, :listener} end, &event/2,
               supervisor: context.supervisor,
               registry: context.registry
             )

    assert_receive {:"$gen_cast", {:effect_finished, {^ref, {:returned, {:ok, :listener}}}}}
    refute_receive {:"$gen_cast", {:effect_finished, _duplicate}}
  end

  test "fast workers cannot exit before terminal-result monitoring is established", context do
    refs = Enum.map(1..200, fn _index -> make_ref() end)

    Enum.each(refs, fn ref ->
      assert {:ok, _coordinator} =
               Effect.start(self(), ref, fn -> :immediate end, &event/2,
                 supervisor: context.supervisor,
                 registry: context.registry
               )
    end)

    outcomes =
      Enum.map(refs, fn _ref ->
        assert_receive {:"$gen_cast", {:effect_finished, {ref, outcome}}}, 2_000
        {ref, outcome}
      end)

    assert MapSet.new(Enum.map(outcomes, &elem(&1, 0))) == MapSet.new(refs)
    assert Enum.all?(outcomes, fn {_ref, outcome} -> outcome == {:returned, :immediate} end)
  end

  test "worker crashes become correlated terminal events", context do
    ref = make_ref()

    assert {:ok, _coordinator} =
             Effect.start(self(), ref, fn -> raise "boom" end, &event/2,
               supervisor: context.supervisor,
               registry: context.registry
             )

    assert_receive {:"$gen_cast",
                    {:effect_finished,
                     {^ref, {:crashed, :error, %RuntimeError{message: "boom"}, stacktrace}}}}

    assert is_list(stacktrace)
  end

  test "a hung worker is terminated and produces a timeout event", context do
    ref = make_ref()
    parent = self()

    assert {:ok, _coordinator} =
             Effect.start(
               self(),
               ref,
               fn ->
                 send(parent, {:worker, self()})
                 Process.sleep(:infinity)
               end,
               &event/2,
               supervisor: context.supervisor,
               registry: context.registry,
               timeout: 10
             )

    assert_receive {:worker, worker}
    assert_receive {:"$gen_cast", {:effect_finished, {^ref, :timed_out}}}, 1_000
    refute Process.alive?(worker)
  end

  test "cancellation produces one terminal event", context do
    ref = make_ref()

    assert {:ok, coordinator} =
             Effect.start(self(), ref, fn -> Process.sleep(:infinity) end, &event/2,
               supervisor: context.supervisor,
               registry: context.registry
             )

    assert :ok = Effect.cancel(coordinator)
    assert_receive {:"$gen_cast", {:effect_finished, {^ref, :cancelled}}}
    refute_receive {:"$gen_cast", {:effect_finished, _duplicate}}
  end

  test "worker cannot outlive its owner epoch", context do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          message -> send(parent, {:owner_message, message})
        end
      end)

    ref = make_ref()

    assert {:ok, coordinator} =
             Effect.start(
               owner,
               ref,
               fn ->
                 send(parent, {:worker, self()})
                 Process.sleep(:infinity)
               end,
               &event/2,
               supervisor: context.supervisor,
               registry: context.registry
             )

    assert_receive {:worker, worker}
    Process.exit(owner, :kill)

    owner_monitor = Process.monitor(coordinator)
    assert_receive {:DOWN, ^owner_monitor, :process, ^coordinator, :normal}
    refute Process.alive?(worker)
    refute_receive {:owner_message, _message}
  end

  defp event(ref, outcome), do: {:effect_finished, {ref, outcome}}
end

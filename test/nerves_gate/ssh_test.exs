defmodule NervesGate.SSHTest do
  use ExUnit.Case, async: false

  alias NervesGate.FSM.Diagnostics
  alias NervesGate.SSH

  setup do
    owner = self()
    {:ok, tailnet} = Agent.start_link(fn -> offline() end)

    starter = fn address ->
      pid = spawn(fn -> listener_loop() end)
      send(owner, {:started, pid, address})
      {:ok, pid}
    end

    stopper = fn pid ->
      send(owner, {:stopped, pid})
      send(pid, :stop)
      :ok
    end

    machine =
      start_machine(
        SSH.new(
          tailnet: fn -> Agent.get(tailnet, & &1) end,
          starter: starter,
          stopper: stopper,
          observer: fn _address -> nil end,
          publisher: fn status -> send(owner, {:status, status}) end,
          retry_delay: 1
        )
      )

    %{machine: machine, tailnet: tailnet}
  end

  test "commands, dependency events, and completion events drive lifecycle state", context do
    assert SSH.status(context.machine).state == :disabled
    assert :ok = SSH.set_enabled(true, context.machine)
    assert SSH.status(context.machine).state == :blocked

    SSH.tailnet_state_changed(online("100.84.12.7"), context.machine)
    assert_receive {:started, listener, {100, 84, 12, 7}}
    assert_eventually(fn -> SSH.status(context.machine).state == :listening end)

    SSH.tailnet_state_changed(offline(), context.machine)
    assert_receive {:stopped, ^listener}
    assert_eventually(fn -> SSH.status(context.machine).state == :blocked end)
  end

  test "listener death is observed and reconciled", context do
    Agent.update(context.tailnet, fn _ -> online("100.84.12.7") end)
    SSH.tailnet_state_changed(online("100.84.12.7"), context.machine)
    assert :ok = SSH.set_enabled(true, context.machine)
    assert_receive {:started, first, {100, 84, 12, 7}}
    assert_eventually(fn -> SSH.status(context.machine).state == :listening end)

    Process.exit(first, :kill)
    transition(context.machine, :retry_timer_fired)

    assert_receive {:stopped, ^first}
    assert_receive {:started, second, {100, 84, 12, 7}}
    assert_eventually(fn -> SSH.status(context.machine).state == :listening end)
    assert Process.alive?(second)
  end

  test "start failures enter backoff and heal starts a new generation", context do
    state = Diagnostics.state(context.machine)

    payload = %{
      state.payload
      | runtime: %{state.payload.runtime | start: fn _ -> {:error, :busy} end}
    }

    :sys.replace_state(context.machine, &%{&1 | payload: payload})
    SSH.tailnet_state_changed(online("100.84.12.7"), context.machine)

    assert :ok = SSH.set_enabled(true, context.machine)
    assert_eventually(fn -> SSH.status(context.machine).state == :backoff end)
    assert SSH.diagnostics(context.machine).last_error == {:listener_start_failed, :busy}

    owner = self()

    :sys.replace_state(context.machine, fn state ->
      starter = fn address ->
        pid = spawn(fn -> listener_loop() end)
        send(owner, {:healed, address})
        {:ok, pid}
      end

      put_in(state.payload.runtime.start, starter)
    end)

    assert :ok = SSH.heal(context.machine)
    assert_receive {:healed, {100, 84, 12, 7}}
    assert_eventually(fn -> SSH.status(context.machine).state == :listening end)
  end

  test "desired changes are coalesced while one mutation is in flight" do
    owner = self()
    {:ok, actual} = Agent.start_link(fn -> nil end)

    starter = fn address ->
      send(owner, {:start_requested, self(), address})

      receive do
        :complete ->
          listener = spawn(fn -> listener_loop() end)
          Agent.update(actual, fn _ -> %{pid: listener, address: address} end)
          {:ok, listener}
      end
    end

    stopper = fn pid ->
      send(owner, {:stopped, pid})
      send(pid, :stop)
      Agent.update(actual, fn _ -> nil end)
      :ok
    end

    machine =
      start_machine(
        SSH.new(
          initial_tailnet: online("100.84.12.7"),
          tailnet: fn -> online("100.84.12.7") end,
          starter: starter,
          stopper: stopper,
          observer: fn _ -> Agent.get(actual, & &1) end,
          publisher: fn _ -> :ok end
        )
      )

    assert :ok = SSH.set_enabled(true, machine)
    assert_receive {:start_requested, first_worker, {100, 84, 12, 7}}

    SSH.tailnet_state_changed(online("100.84.12.8"), machine)
    refute_receive {:start_requested, _overlapping_worker, _address}, 50

    send(first_worker, :complete)
    assert_receive {:stopped, first_listener}
    assert_receive {:start_requested, second_worker, {100, 84, 12, 8}}
    refute first_worker == second_worker

    send(second_worker, :complete)
    assert_eventually(fn -> SSH.status(machine).address == "100.84.12.8" end)
    assert Process.alive?(Agent.get(actual, & &1).pid)
    refute Process.alive?(first_listener)
  end

  test "stale completion cannot advance the active generation" do
    owner = self()

    starter = fn address ->
      send(owner, {:start_requested, self(), address})
      receive do: (:complete -> {:error, :busy})
    end

    machine =
      start_machine(
        SSH.new(
          initial_tailnet: online("100.84.12.7"),
          tailnet: fn -> online("100.84.12.7") end,
          starter: starter,
          observer: fn _ -> nil end,
          publisher: fn _ -> :ok end
        )
      )

    assert :ok = SSH.set_enabled(true, machine)
    assert_receive {:start_requested, worker, _address}
    active_ref = Diagnostics.state(machine).payload.effect.ref

    GenServer.cast(machine, {:reconciliation_completed, {make_ref(), {:returned, {:ok, nil}}}})
    Process.sleep(10)

    assert Diagnostics.state(machine).payload.effect.ref == active_ref
    assert SSH.status(machine).state == :reconciling
    send(worker, :complete)
  end

  test "a timed out runtime mutation reaches a terminal state" do
    machine =
      start_machine(
        SSH.new(
          initial_tailnet: online("100.84.12.7"),
          tailnet: fn -> online("100.84.12.7") end,
          starter: fn _ -> Process.sleep(:infinity) end,
          observer: fn _ -> nil end,
          publisher: fn _ -> :ok end,
          effect_timeout: 20
        )
      )

    assert :ok = SSH.set_enabled(true, machine)
    assert_eventually(fn -> SSH.status(machine).state == :backoff end)
    assert SSH.diagnostics(machine).last_error == :listener_reconciliation_timed_out
  end

  test "restart observes ambiguous external success before mutating again" do
    owner = self()
    {:ok, actual} = Agent.start_link(fn -> nil end)
    {:ok, starts} = Agent.start_link(fn -> 0 end)

    starter = fn address ->
      Agent.update(starts, &(&1 + 1))
      listener = spawn(fn -> listener_loop() end)
      Agent.update(actual, fn _ -> %{pid: listener, address: address} end)
      send(owner, :external_mutation_succeeded)
      Process.sleep(:infinity)
    end

    options = [
      enabled: true,
      initial_tailnet: online("100.84.12.7"),
      tailnet: fn -> online("100.84.12.7") end,
      starter: starter,
      observer: fn _ -> Agent.get(actual, & &1) end,
      valid?: fn listener, address -> listener && listener.address == address end,
      stopper: fn _ -> :ok end,
      publisher: fn _ -> :ok end
    ]

    machine = start_machine(SSH.new(options))
    assert :ok = SSH.set_enabled(true, machine)
    assert_receive :external_mutation_succeeded

    Process.unlink(machine)
    Process.exit(machine, :kill)
    assert_eventually(fn -> not Process.alive?(machine) end)

    replacement = start_machine(SSH.new(options))
    assert :ok = SSH.set_enabled(true, replacement)
    assert_eventually(fn -> SSH.status(replacement).state == :listening end)
    assert Agent.get(starts, & &1) == 1
  end

  test "diagnostic transition history is bounded" do
    machine =
      start_machine(
        SSH.new(
          tailnet: fn -> offline() end,
          observer: fn _ -> nil end,
          publisher: fn _ -> :ok end
        )
      )

    Enum.each(1..60, fn _ -> transition(machine, :retry_timer_fired) end)
    assert Enum.count(SSH.diagnostics(machine).history) == 30
  end

  defp start_machine(payload) do
    name = String.to_atom("ssh_machine_#{System.unique_integer([:positive])}")
    {:ok, machine} = SSH.start_link(payload: payload, name: name)
    machine
  end

  defp transition(machine, event) do
    assert {:ok, _state} = Diagnostics.transition(machine, event)
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

  defp offline, do: %{online: false, ipv4: nil}
  defp online(ipv4), do: %{online: true, ipv4: ipv4}

  defp listener_loop do
    receive do
      :stop -> :ok
    end
  end
end

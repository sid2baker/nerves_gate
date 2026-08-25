defmodule NervesGate.SubnetRouterTest do
  use ExUnit.Case, async: true

  alias NervesGate.SubnetRouter

  setup do
    owner = self()
    {:ok, tailnet} = Agent.start_link(fn -> offline() end)

    apply = fn enabled, routes ->
      send(owner, {:apply, enabled, routes})
      {:ok, routes}
    end

    name = String.to_atom("subnet_machine_#{System.unique_integer([:positive])}")

    payload =
      SubnetRouter.new(
        tailnet: fn -> Agent.get(tailnet, & &1) end,
        apply: apply,
        publisher: fn _ -> :ok end,
        retry_delay: 1
      )

    {:ok, machine} = SubnetRouter.start_link(payload: payload, name: name)
    %{machine: machine, tailnet: tailnet}
  end

  test "desired routes block on Tailnet then await approval and become active", context do
    routes = ["192.168.10.0/24"]
    assert {:ok, ^routes} = SubnetRouter.configure(true, routes, context.machine)
    assert_eventually(fn -> SubnetRouter.diagnostics(context.machine).state == :blocked end)

    status = online([], [])
    Agent.update(context.tailnet, fn _ -> status end)
    SubnetRouter.tailnet_state_changed(status, context.machine)
    assert_receive {:apply, true, ^routes}

    assert_eventually(fn ->
      SubnetRouter.diagnostics(context.machine).state == :awaiting_approval
    end)

    status = online(routes, routes)
    Agent.update(context.tailnet, fn _ -> status end)
    SubnetRouter.tailnet_state_changed(status, context.machine)
    assert_eventually(fn -> SubnetRouter.diagnostics(context.machine).state == :active end)
  end

  test "Tailnet loss blocks active routes without mutating desired state", context do
    routes = ["10.20.0.0/16"]
    status = online(routes, routes)
    Agent.update(context.tailnet, fn _ -> status end)
    SubnetRouter.tailnet_state_changed(status, context.machine)

    assert {:ok, ^routes} = SubnetRouter.configure(true, routes, context.machine)
    assert_eventually(fn -> SubnetRouter.diagnostics(context.machine).state == :active end)

    Agent.update(context.tailnet, fn _ -> offline() end)
    SubnetRouter.tailnet_state_changed(offline(), context.machine)
    assert_eventually(fn -> SubnetRouter.diagnostics(context.machine).state == :blocked end)
    assert SubnetRouter.status(context.machine).routes == routes
  end

  test "local application failure reaches backoff and heal starts another generation", context do
    failing = fn _enabled, _routes -> {:error, :daemon} end
    :sys.replace_state(context.machine, &%{&1 | apply: failing})
    status = online([], [])
    Agent.update(context.tailnet, fn _ -> status end)
    SubnetRouter.tailnet_state_changed(status, context.machine)

    assert {:ok, ["192.0.2.0/24"]} =
             SubnetRouter.configure(true, ["192.0.2.0/24"], context.machine)

    assert_eventually(fn -> SubnetRouter.diagnostics(context.machine).state == :backoff end)

    apply = fn _enabled, routes -> {:ok, routes} end
    :sys.replace_state(context.machine, &%{&1 | apply: apply})
    assert :ok = SubnetRouter.heal(context.machine)

    assert_eventually(fn ->
      SubnetRouter.diagnostics(context.machine).state == :awaiting_approval
    end)
  end

  test "route mutations serialize and coalesce the newest desired state", context do
    owner = self()

    apply = fn enabled, routes ->
      send(owner, {:apply_started, self(), enabled, routes})
      receive do: (:complete -> {:ok, routes})
    end

    :sys.replace_state(context.machine, &%{&1 | apply: apply})
    status = online([], [])
    Agent.update(context.tailnet, fn _ -> status end)
    SubnetRouter.tailnet_state_changed(status, context.machine)

    assert {:ok, ["10.0.0.0/8"]} =
             SubnetRouter.configure(true, ["10.0.0.0/8"], context.machine)

    assert_receive {:apply_started, first, true, ["10.0.0.0/8"]}

    assert {:ok, ["192.168.0.0/16"]} =
             SubnetRouter.configure(true, ["192.168.0.0/16"], context.machine)

    refute_receive {:apply_started, _overlap, _enabled, _routes}, 50
    send(first, :complete)
    assert_receive {:apply_started, second, true, ["192.168.0.0/16"]}
    send(second, :complete)

    assert_eventually(fn -> SubnetRouter.status(context.machine).routes == ["192.168.0.0/16"] end)
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

  defp offline do
    %{
      online: false,
      subnet_router: %{advertised: [], approved: [], primary: [], error: :unavailable}
    }
  end

  defp online(advertised, approved) do
    %{
      online: true,
      subnet_router: %{advertised: advertised, approved: approved, primary: [], error: nil}
    }
  end
end

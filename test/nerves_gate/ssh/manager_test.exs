defmodule NervesGate.SSH.ManagerTest do
  use ExUnit.Case, async: true

  alias NervesGate.SSH.Manager
  alias NervesSSH.Options

  setup do
    owner = self()

    starter = fn options ->
      pid = spawn(fn -> listener_loop() end)
      send(owner, {:listener_started, pid, options})
      {:ok, pid}
    end

    stopper = fn pid ->
      send(owner, {:listener_stopped, pid})
      send(pid, :stop)
      :ok
    end

    publisher = fn status -> send(owner, {:ssh_changed, status}) end
    alarm_reporter = fn _status -> :ok end

    %{starter: starter, stopper: stopper, publisher: publisher, alarm_reporter: alarm_reporter}
  end

  test "disabled SSH never starts with or without Tailnet", context do
    manager = start_manager(context, offline())
    assert Manager.status(manager).state == :disabled
    refute_receive {:listener_started, _, _}

    send(manager, {:tailnet_changed, online("100.84.12.7")})
    assert_eventually(fn -> Manager.status(manager).state == :disabled end)
    refute_receive {:listener_started, _, _}
  end

  test "enabled SSH waits without a valid Tailnet IPv4 address", context do
    manager = start_manager(context, offline())
    assert :ok = Manager.set_enabled(true, manager)

    assert Manager.status(manager) == %{
             enabled: true,
             state: :waiting_for_tailnet,
             address: nil,
             port: 22
           }

    for address <- [
          "0.0.0.0",
          "10.0.0.4",
          "100.63.255.255",
          "100.128.0.1",
          "192.168.1.20",
          nil
        ] do
      send(manager, {:tailnet_changed, %{online: true, ipv4: address}})
    end

    refute_receive {:listener_started, _, _}
    assert Manager.status(manager).state == :waiting_for_tailnet
  end

  test "enabled SSH binds keyless NervesSSH only to the exact Tailscale address", context do
    manager = start_manager(context, online("100.84.12.7"))
    assert :ok = Manager.set_enabled(true, manager)

    assert_receive {:listener_started, _pid, options}
    assert options.port == 22
    assert options.shell == :elixir
    assert options.exec == :disabled
    assert options.authorized_keys == []
    assert options.subsystems == []
    assert options.daemon_option_overrides[:inet] == :inet
    assert options.daemon_option_overrides[:ip] == {100, 84, 12, 7}
    assert options.daemon_option_overrides[:no_auth_needed]
    refute options.daemon_option_overrides[:ip] in [:any, {0, 0, 0, 0}]

    daemon_options = Options.daemon_options(options)
    assert daemon_options[:inet] == :inet
    assert daemon_options[:ip] == {100, 84, 12, 7}
    assert daemon_options[:no_auth_needed]

    assert Manager.status(manager) == %{
             enabled: true,
             state: :listening,
             address: {100, 84, 12, 7},
             port: 22
           }
  end

  test "listener startup failures are reported without changing the bind address", context do
    context = %{context | starter: fn _options -> {:error, :eaddrinuse} end}
    manager = start_manager(context, online("100.84.12.7"))

    assert :ok = Manager.set_enabled(true, manager)

    assert Manager.status(manager) == %{
             enabled: true,
             state: :error,
             address: nil,
             port: 22
           }

    refute_receive {:listener_started, _, _}
  end

  test "Tailnet loss stops the listener and reconnection starts it again", context do
    manager = start_manager(context, online("100.84.12.7"))
    assert :ok = Manager.set_enabled(true, manager)
    assert_receive {:listener_started, first, _options}

    send(manager, {:tailnet_changed, offline()})
    assert_receive {:listener_stopped, ^first}
    assert_eventually(fn -> Manager.status(manager).state == :waiting_for_tailnet end)

    send(manager, {:tailnet_changed, online("100.84.12.7")})
    assert_receive {:listener_started, second, _options}
    assert second != first
    assert_eventually(fn -> Manager.status(manager).state == :listening end)
  end

  test "a Tailnet address change moves the listener", context do
    manager = start_manager(context, online("100.84.12.7"))
    assert :ok = Manager.set_enabled(true, manager)
    assert_receive {:listener_started, first, first_options}
    assert first_options.daemon_option_overrides[:ip] == {100, 84, 12, 7}

    send(manager, {:tailnet_changed, online("100.84.12.8")})
    assert_receive {:listener_stopped, ^first}
    assert_receive {:listener_started, second, second_options}
    assert second != first
    assert second_options.daemon_option_overrides[:ip] == {100, 84, 12, 8}
    assert_eventually(fn -> Manager.status(manager).address == {100, 84, 12, 8} end)
  end

  test "disable stops immediately and enable restarts only while Tailnet is ready", context do
    manager = start_manager(context, online("100.84.12.7"))
    assert :ok = Manager.set_enabled(true, manager)
    assert_receive {:listener_started, listener, _options}

    assert :ok = Manager.set_enabled(false, manager)
    assert_receive {:listener_stopped, ^listener}
    assert Manager.status(manager).state == :disabled

    assert :ok = Manager.set_enabled(true, manager)
    assert_receive {:listener_started, _listener, _options}
  end

  defp start_manager(context, tailnet) do
    name = String.to_atom("ssh_manager_#{System.unique_integer([:positive])}")

    {:ok, manager} =
      Manager.start_link(
        name: name,
        subscribe: false,
        tailnet: tailnet,
        starter: context.starter,
        stopper: context.stopper,
        publisher: context.publisher,
        alarm_reporter: context.alarm_reporter
      )

    on_exit(fn ->
      if Process.alive?(manager) do
        Manager.set_enabled(false, manager)
        GenServer.stop(manager)
      end
    end)

    manager
  end

  defp offline, do: %{online: false, ipv4: nil}
  defp online(ipv4), do: %{online: true, ipv4: ipv4}

  defp listener_loop do
    receive do
      :stop -> :ok
    end
  end

  defp assert_eventually(predicate, attempts \\ 50) do
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

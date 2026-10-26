defmodule Scenarios.Recovery do
  @moduledoc "Local management recovery checks, not proof of access through the tailnet."
  import ExUnit.Assertions
  alias Scenarios.Device
  alias Scenarios.Qemu, as: Qemu

  # Guest supervisor children only. Never accept host PIDs or daemon OS PIDs.
  @targets [
    NervesGate.SSH,
    NervesGate.Network,
    NervesGate.Remote,
    NervesGate.Indicators,
    NervesGate.Buses,
    NervesGate.ProjectionServer,
    NervesGateWeb.Endpoint
  ]

  # Only known, guest-owned workers. Registry partitions link subscribers, so
  # losing one also restarts ProjectionServer and the Endpoint after it.
  @registries [
    {:registry, NervesGate.Properties.Subscriptions},
    {:registry, VintageNet.Subscriptions},
    {:registry, Tailscaled.Properties.Subscriptions}
  ]
  @dependencies [VintageNet.Updater, Tailscaled.Daemon, {VintageNet.Interface, "eth0"}] ++
                  @registries

  def targets, do: @targets
  def dependencies, do: @dependencies

  def snapshot(vm) do
    %{
      boot: %{
        kernel: :erpc.call(vm.node, File, :read!, ["/proc/sys/kernel/random/boot_id"], 2_000),
        beam: :erpc.call(vm.node, :erlang, :system_info, [:creation], 2_000)
      },
      children:
        vm.node
        |> :erpc.call(Supervisor, :which_children, [NervesGate.Supervisor], 2_000)
        |> Enum.reverse()
        |> Enum.map(fn {id, pid, _, _} -> {id, pid} end)
    }
  end

  def baseline(vm) do
    status =
      Scenarios.Device.await(vm, "Local recovery baseline", fn status ->
        Device.addressed?(status) and status.network.pending == nil and
          status.remote.available and status.remote.operation == nil and
          http_ready?(vm)
      end)

    before = Map.put(snapshot(vm), :saved, saved(status))
    event(vm, :baseline, before)
    before
  end

  @doc "Fail a target `times` times in a row, each after its restart, then await recovery."
  def crash(vm, target, times \\ 1)

  def crash(vm, target, times) when target in @targets and times in 1..2 do
    before = baseline(vm)
    {_, pid, type, _} = child(vm, target)
    assert is_pid(pid), "Guest target is not running: #{inspect(target)}"
    fault_at = now()
    restarts = before.children |> Enum.drop_while(fn {id, _} -> id != target end)

    event(vm, :crash, %{
      target: target,
      type: type,
      times: times,
      pid: pid,
      boot: before.boot,
      expected_restarts: Enum.map(restarts, &elem(&1, 0))
    })

    fail_times(vm, target, pid, type, times)
    await_recovery(vm, before, target, fault_at: fault_at)
  end

  def crash(vm, dependency, 1) when dependency in @dependencies do
    before = baseline(vm)
    pid = dependency_pid(vm, dependency)
    assert is_pid(pid), "Guest dependency is not running: #{inspect(dependency)}"
    fault_at = now()
    scope = if dependency in @registries, do: NervesGate.ProjectionServer

    event(vm, :crash, %{
      target: dependency,
      type: :dependency,
      pid: pid,
      boot: before.boot,
      gateway_restart_from: scope
    })

    fail(vm, pid, :worker)

    replacement(fn -> dependency_pid(vm, dependency) end, pid, now() + 30_000) ||
      flunk("#{inspect(dependency)} did not restart; evidence: #{vm.dir}/recovery.log")

    await_recovery(vm, before, scope, fault_at: fault_at, timeout: 60_000, label: dependency)
  end

  @doc "Kill a gateway worker and return its restarted PID."
  def restart_worker(vm, target) when target in @targets do
    {_, pid, :worker, _} = child(vm, target)
    fail(vm, pid, :worker)
    restarted!(vm, target, pid)
  end

  @doc "Crash a worker until its supervisor stops restarting it; returns the crash count."
  def crash_loop(vm, target) when target in @targets do
    {_, pid, :worker, _} = child(vm, target)
    event(vm, :crash_loop, %{target: target, pid: pid})
    crash_until_stopped(vm, target, pid, 1)
  end

  defp crash_until_stopped(vm, target, pid, crashes) do
    event(vm, :crash_loop_step, %{target: target, pid: pid, crashes: crashes})
    fail(vm, pid, :worker)

    case replacement(fn -> child_pid(vm, target) end, pid, now() + 2_000) do
      nil ->
        event(vm, :restarts_exhausted, %{target: target, crashes: crashes})
        crashes

      next when crashes < 20 ->
        crash_until_stopped(vm, target, next, crashes + 1)

      _ ->
        flunk("#{inspect(target)} still restarts after #{crashes} crashes")
    end
  end

  defp fail_times(vm, _target, pid, type, 1), do: fail(vm, pid, type)

  defp fail_times(vm, target, pid, type, times) do
    fail(vm, pid, type)
    fail_times(vm, target, restarted!(vm, target, pid), type, times - 1)
  end

  # Workers die without cleanup. An OTP supervisor fails only after stopping its
  # children, exiting :shutdown. Killing one brutally orphans named children that
  # then race its restart; OTP never produces that failure, so it is not injected.
  defp fail(vm, pid, :worker),
    do: assert(:erpc.call(vm.node, Process, :exit, [pid, :kill], 2_000))

  defp fail(vm, pid, :supervisor),
    do: assert(:ok = :erpc.call(vm.node, :sys, :terminate, [pid, :shutdown, 15_000], 20_000))

  # Network's init restores saved settings within two bounded 10-second steps.
  defp restarted!(vm, target, pid) do
    replacement(fn -> child_pid(vm, target) end, pid, now() + 30_000) ||
      flunk("#{inspect(target)} did not restart; evidence: #{vm.dir}/recovery.log")
  end

  # The next PID, or nil after the deadline, a stopped supervisor or node loss.
  defp replacement(read, previous, deadline) do
    case current(read) do
      pid when is_pid(pid) and pid != previous ->
        pid

      :stopped ->
        nil

      _ ->
        if now() < deadline do
          Process.sleep(10)
          replacement(read, previous, deadline)
        end
    end
  end

  # A supervisor does not answer while a restarting child's init is still running:
  # that timeout means busy, not stopped.
  defp current(read) do
    read.()
  catch
    :error, {:erpc, :timeout} -> :busy
    :error, {:erpc, _} -> :stopped
    :exit, {:exception, {reason, _}} when reason in [:noproc, :shutdown] -> :stopped
  end

  defp child_pid(vm, target) do
    case child(vm, target) do
      {_, pid, _, _} -> pid
      nil -> nil
    end
  end

  defp child(vm, target) do
    vm.node
    |> :erpc.call(Supervisor, :which_children, [NervesGate.Supervisor], 2_000)
    |> List.keyfind(target, 0)
  end

  defp dependency_pid(vm, {VintageNet.Interface, ifname}) do
    via = {:via, Registry, {VintageNet.Interface.Registry, ifname}}
    :erpc.call(vm.node, GenServer, :whereis, [via], 2_000)
  end

  defp dependency_pid(vm, {:registry, registry}) do
    # Discover the live partition through its owner. Keep the same child ID
    # across replacement checks without depending on Registry's generated names.
    vm.node
    |> :erpc.call(Supervisor, :which_children, [registry], 2_000)
    |> Enum.filter(fn {_, _, type, modules} ->
      type == :worker and Registry.Partition in modules
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> case do
      [{_, pid, _, _} | _] when is_pid(pid) -> pid
      _ -> nil
    end
  end

  defp dependency_pid(vm, name), do: :erpc.call(vm.node, Process, :whereis, [name], 2_000)

  @doc """
  Await stable health. A target `nil` requires every gateway child unchanged;
  `:reboot` requires a new kernel boot with the same children and saved state.
  """
  def await_recovery(vm, before, target, options \\ [])
      when target in @targets or target in [nil, :reboot] do
    timeout = Keyword.get(options, :timeout, 30_000)
    # OTP counts an inclusive, whole-second restart window. Six quiet seconds
    # age out a five-second window even when a fault lands on a second boundary.
    stability = Keyword.get(options, :stability, 6_000)
    fault_at = Keyword.get(options, :fault_at, now())
    label = Keyword.get(options, :label, target)
    phase = "Local recovery: #{inspect(label)} (#{stability} ms stable)"
    if report = Process.get(:qemu_report), do: report.(phase)

    poll(vm, before, target, %{
      label: label,
      fault_at: fault_at,
      deadline: fault_at + timeout,
      stability: stability,
      stable_at: nil,
      candidate: nil,
      outage_at: nil
    })
  end

  # A fresh, bounded request on the private management forward. No body is logged,
  # even on failure: error pages can contain private state. Never follow redirects.
  def http_ready?(vm) do
    case Req.get(Qemu.ui_url(vm) <> "/",
           retry: false,
           redirect: false,
           decode_body: false,
           headers: [connection: "close"],
           finch: [
             conn_opts: [transport_opts: [timeout: 1_000]],
             pool_timeout: 1_000,
             receive_timeout: 2_000,
             request_timeout: 3_000
           ]
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        String.contains?(body, ~s(id="connection-internet")) and
          String.contains?(body, to_string(vm.node))

      _ ->
        false
    end
  end

  @doc """
  The UI read model must follow changes through NervesGate's and VintageNet's
  property tables, not only direct status reads.
  """
  def assert_projection_follows(vm) do
    {_private, line, fingerprint} = Device.ssh_key()
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.SSH, :add_key, [line])
    await_projection(vm, "UI projection shows an added SSH key", &(fingerprint in keys(&1)))
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.SSH, :remove_key, [fingerprint])
    await_projection(vm, "UI projection drops a removed SSH key", &(fingerprint not in keys(&1)))

    assert :ok = Qemu.network(vm, %{cables: %{lan1: false}})

    await_projection(vm, "UI projection shows LAN1 unplugged", fn status ->
      Enum.any?(status.connections.ports, &match?(%{name: "eth0", link: false}, &1))
    end)

    assert :ok = Qemu.network(vm, %{cables: %{lan1: true}})

    await_projection(
      vm,
      "UI projection shows LAN1 addressed",
      &Device.addressed?/1,
      60_000
    )

    Scenarios.Device.await(
      vm,
      "Internet recovered and its warning cleared",
      fn status ->
        Device.internet?(status) and
          :erpc.call(
            vm.node,
            Alarmist,
            :alarm_state,
            [{NervesGate.Alarms.Warning, NervesGate.Network, :internet_unavailable}],
            2_000
          ) == :clear
      end,
      60_000
    )
  end

  defp keys(status), do: Enum.map(status.ssh.keys, & &1.fingerprint)

  defp await_projection(vm, phase, predicate, timeout \\ 15_000) do
    if report = Process.get(:qemu_report), do: report.(phase)
    await_projection_until(vm, phase, predicate, now() + timeout)
  end

  defp await_projection_until(vm, phase, predicate, deadline) do
    status = projection(vm)

    cond do
      status && predicate.(status) ->
        event(vm, :projection_followed, %{phase: phase})

      now() >= deadline ->
        event(vm, :projection_timeout, %{phase: phase})
        flunk("Timed out: #{phase}; evidence: #{vm.dir}/recovery.log")

      true ->
        Process.sleep(250)
        await_projection_until(vm, phase, predicate, deadline)
    end
  end

  defp projection(vm) do
    :erpc.call(vm.node, NervesGate.ProjectionServer, :snapshot, [], 2_000).status
  catch
    :error, {:erpc, _} -> nil
    :exit, {:exception, _} -> nil
  end

  def capture_failure(vm) do
    # Inspect each source independently: a missing supervisor must not discard the
    # surviving logger's evidence. Only fixed error tags leave the raw log buffer.
    event(vm, :failure_before_cleanup, %{
      snapshot: diagnostic(fn -> snapshot(vm) end),
      error_tags: diagnostic(fn -> error_tags(vm) end),
      alarm_ids: diagnostic(fn -> alarm_ids(vm) end)
    })
  catch
    _, _ -> diagnostic_unavailable(vm)
  end

  defp diagnostic(read) do
    read.()
  catch
    _, _ -> :unavailable
  end

  defp alarm_ids(vm) do
    vm.node
    |> :erpc.call(Alarmist, :get_alarm_ids, [[level: :debug]], 2_000)
    |> Enum.filter(fn id ->
      match?({NervesGate.Alarms, _, _}, id) or
        match?({NervesGate.Alarms.Warning, _, _}, id)
    end)
  end

  defp error_tags(vm) do
    logs = :erpc.call(vm.node, RingLogger.Server, :tail, [100], 2_000)

    for entry <- logs,
        message = IO.chardata_to_string(entry.message),
        tags =
          Enum.filter(
            ~w(nerves_gate terminating shutdown killed failed_to_start_child already_started eaddrinuse reached_max_restart_intensity badarg timeout exited start_error child_terminated),
            &String.contains?(message, &1)
          ),
        tags != [] do
      %{
        at: entry.timestamp,
        level: entry.level,
        tags: tags,
        modules:
          Enum.filter(@targets ++ [Phoenix.Config], &String.contains?(message, inspect(&1)))
      }
    end
  end

  defp diagnostic_unavailable(vm) do
    event(vm, :failure_diagnostics_unavailable, %{})
  catch
    _, _ -> :ok
  end

  defp poll(vm, before, target, timing) do
    sample = sample(vm, before, target)
    observed_at = now()

    timing = observe(sample, timing, observed_at)

    cond do
      stable?(timing, observed_at) ->
        event(vm, :recovered, %{
          target: timing.label,
          outage_observed: timing.outage_at != nil,
          outage_after_ms: timing.outage_at && timing.outage_at - timing.fault_at,
          recovery_ms: timing.stable_at - timing.fault_at,
          stable_ms: observed_at - timing.stable_at,
          boot: sample.boot,
          children: sample.children
        })

        :ok

      observed_at >= timing.deadline ->
        event(vm, :recovery_timeout, %{
          target: timing.label,
          elapsed_ms: observed_at - timing.fault_at
        })

        flunk(
          "Local recovery timed out for #{inspect(timing.label)}; evidence: #{vm.dir}/recovery.log"
        )

      true ->
        Process.sleep(500)
        poll(vm, before, target, timing)
    end
  end

  defp observe(sample, timing, observed_at) do
    if sample && sample == timing.candidate do
      timing
    else
      %{
        timing
        | stable_at: if(sample, do: observed_at),
          candidate: sample,
          outage_at: timing.outage_at || if(!sample, do: observed_at)
      }
    end
  end

  defp stable?(timing, observed_at) do
    timing.stable_at != nil and observed_at - timing.stable_at >= timing.stability and
      observed_at <= timing.deadline
  end

  defp sample(vm, before, target) do
    status = Scenarios.Device.status(vm)
    current = snapshot(vm)

    if boot?(before.boot, current.boot, target) and
         scope?(before.children, current.children, target) and
         healthy?(status, before.saved) and http_ready?(vm),
       do: current
  catch
    :error, {:erpc, _} -> nil
    :exit, {:exception, {reason, _}} when reason in [:noproc, :shutdown] -> nil
  end

  # Only a reboot replaces the kernel and the BEAM.
  defp boot?(before, current, :reboot),
    do: current.kernel != before.kernel and current.beam != before.beam

  defp boot?(before, current, _target), do: current == before

  defp healthy?(nil, _saved), do: false

  defp healthy?(status, saved) do
    saved(status) == saved and Device.addressed?(status) and
      status.network.pending == nil and status.remote.available and
      status.remote.operation == nil
  end

  # The actual startup order determines the legitimate rest_for_one restart scope.
  # A nil target is a no-fault stability check, also used by probe negative controls.
  defp scope?(before, current, :reboot) do
    ids(before) == ids(current) and
      Enum.all?(before, fn {id, pid} ->
        replacement = Keyword.get(current, id)
        if is_pid(pid), do: is_pid(replacement), else: replacement == pid
      end)
  end

  defp scope?(before, current, target) do
    {unchanged, restarted} = Enum.split_while(before, fn {id, _} -> id != target end)

    ids(before) == ids(current) and
      Enum.all?(unchanged, fn {id, pid} -> Keyword.get(current, id) == pid end) and
      Enum.all?(restarted, fn {id, pid} ->
        replacement = Keyword.get(current, id)
        is_pid(replacement) and replacement != pid
      end)
  end

  defp ids(children), do: Enum.map(children, &elem(&1, 0))

  defp saved(status) do
    %{
      settings: status.network.desired,
      setup_completed: status.network.setup_completed,
      ssh_keys: Enum.map(status.ssh.keys, & &1.fingerprint) |> Enum.sort(),
      remote: Map.take(status.remote, [:auth_state, :hostname, :dns_name, :ipv4])
    }
  end

  def event(vm, name, data) do
    File.write!(
      Path.join(vm.dir, "recovery.log"),
      "#{now()} #{name} #{inspect(data, limit: :infinity)}\n",
      [:append]
    )
  end

  defp now, do: System.monotonic_time(:millisecond)
end

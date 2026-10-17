defmodule NervesGate.RecoveryChecks do
  @moduledoc "Local management recovery checks, not proof of access through the tailnet."
  import ExUnit.Assertions
  alias NervesGate.ScenarioHelpers
  alias NervesGate.TestQemu, as: Qemu

  # Guest supervisor children only. Never accept host PIDs or daemon OS PIDs.
  @targets [
    NervesGate.SSH,
    NervesGate.Network,
    NervesGate.Remote,
    NervesGate.Equipment,
    NervesGate.Indicators,
    NervesGate.Buses,
    NervesGate.ProjectionServer,
    NervesGateWeb.Endpoint
  ]

  def targets, do: @targets

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
      Qemu.await(vm, "Local recovery baseline", fn status ->
        ScenarioHelpers.addressed?(status) and status.network.pending == nil and
          status.remote_access.available and status.remote_access.operation == nil and
          http_ready?(vm)
      end)

    before = Map.put(snapshot(vm), :saved, saved(status))
    event(vm, :baseline, before)
    before
  end

  def crash(vm, target) when target in @targets do
    before = baseline(vm)
    pid = Keyword.fetch!(before.children, target)
    assert is_pid(pid), "Guest target is not running: #{inspect(target)}"

    {_, ^pid, type, _} =
      vm.node
      |> :erpc.call(Supervisor, :which_children, [NervesGate.Supervisor], 2_000)
      |> List.keyfind(target, 0)

    fault_at = now()
    restarts = before.children |> Enum.drop_while(fn {id, _} -> id != target end)

    event(vm, :crash, %{
      target: target,
      type: type,
      pid: pid,
      boot: before.boot,
      expected_restarts: Enum.map(restarts, &elem(&1, 0))
    })

    fail(vm, pid, type)
    await_recovery(vm, before, target, fault_at: fault_at)
  end

  # Workers die without cleanup. An OTP supervisor fails only after stopping its
  # children, exiting :shutdown. Killing one brutally orphans named children that
  # then race its restart; OTP never produces that failure, so it is not injected.
  defp fail(vm, pid, :worker),
    do: assert(:erpc.call(vm.node, Process, :exit, [pid, :kill], 2_000))

  defp fail(vm, pid, :supervisor),
    do: assert(:ok = :erpc.call(vm.node, :sys, :terminate, [pid, :shutdown, 15_000], 20_000))

  def await_recovery(vm, before, target, options \\ [])
      when target in @targets or is_nil(target) do
    timeout = Keyword.get(options, :timeout, 30_000)
    stability = Keyword.get(options, :stability, 5_000)
    fault_at = Keyword.get(options, :fault_at, now())
    phase = "Local recovery: #{inspect(target)} (#{stability} ms stable)"
    if report = Process.get(:qemu_report), do: report.(phase)

    poll(vm, before, target, %{
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
    case Req.get("http://#{vm.address}:#{vm.forwards.http}/",
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

  def capture_failure(vm) do
    # Inspect each source independently: a missing supervisor must not discard the
    # surviving logger's evidence. Only fixed error tags leave the raw log buffer.
    event(vm, :failure_before_cleanup, %{
      snapshot: diagnostic(fn -> snapshot(vm) end),
      error_tags: diagnostic(fn -> error_tags(vm) end)
    })
  rescue
    _ -> diagnostic_unavailable(vm)
  catch
    _, _ -> diagnostic_unavailable(vm)
  end

  defp diagnostic(read) do
    read.()
  rescue
    _ -> :unavailable
  catch
    _, _ -> :unavailable
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
  rescue
    _ -> :ok
  end

  defp poll(vm, before, target, timing) do
    sample = sample(vm, before, target)
    observed_at = now()

    timing = observe(sample, timing, observed_at)

    cond do
      stable?(timing, observed_at) ->
        event(vm, :recovered, %{
          target: target,
          outage_observed: timing.outage_at != nil,
          outage_after_ms: timing.outage_at && timing.outage_at - timing.fault_at,
          recovery_ms: timing.stable_at - timing.fault_at,
          stable_ms: observed_at - timing.stable_at,
          children: sample.children
        })

        :ok

      observed_at >= timing.deadline ->
        event(vm, :recovery_timeout, %{target: target, elapsed_ms: observed_at - timing.fault_at})
        flunk("Local recovery timed out for #{inspect(target)}; evidence: #{vm.dir}/recovery.log")

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
    status = Qemu.status(vm)
    current = snapshot(vm)

    if current.boot == before.boot and scope?(before.children, current.children, target) and
         healthy?(status, before.saved) and http_ready?(vm),
       do: current
  catch
    :error, {:erpc, _} -> nil
    :exit, {:exception, {:noproc, _}} -> nil
  end

  defp healthy?(nil, _saved), do: false

  defp healthy?(status, saved) do
    saved(status) == saved and ScenarioHelpers.addressed?(status) and
      status.network.pending == nil and status.remote_access.available and
      status.remote_access.operation == nil
  end

  # The actual startup order determines the legitimate rest_for_one restart scope.
  # A nil target is a no-fault stability check, also used by probe negative controls.
  defp scope?(before, current, target) do
    {unchanged, restarted} = Enum.split_while(before, fn {id, _} -> id != target end)

    Enum.map(before, &elem(&1, 0)) == Enum.map(current, &elem(&1, 0)) and
      Enum.all?(unchanged, fn {id, pid} -> Keyword.get(current, id) == pid end) and
      Enum.all?(restarted, fn {id, pid} ->
        replacement = Keyword.get(current, id)
        is_pid(replacement) and replacement != pid
      end)
  end

  defp saved(status) do
    %{
      settings: status.network.desired,
      setup_completed: status.network.setup_completed,
      ssh_keys: Enum.map(status.ssh.keys, & &1.fingerprint) |> Enum.sort(),
      remote: Map.take(status.remote_access, [:auth_state, :hostname, :dns_name, :ipv4])
    }
  end

  defp event(vm, name, data) do
    File.write!(
      Path.join(vm.dir, "recovery.log"),
      "#{now()} #{name} #{inspect(data, limit: :infinity)}\n",
      [:append]
    )
  end

  defp now, do: System.monotonic_time(:millisecond)
end

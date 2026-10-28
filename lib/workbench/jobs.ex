defmodule Workbench.Jobs do
  @moduledoc """
  One serialized long-running job at a time: firmware builds, plugin
  test/package/install, reviewed physical firmware updates and factory provisioning.
  A review is consumed once by its confirmation. Every change is published.
  """
  use GenServer

  @topic "jobs"
  @ttl_ms 600_000

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)
  def history, do: GenServer.call(__MODULE__, :history)
  def fetch(id), do: GenServer.call(__MODULE__, {:fetch, id})
  def subscribe, do: Phoenix.PubSub.subscribe(NervesGate.PubSub, @topic)

  def build(target, expected \\ Workbench.Session.identity()),
    do: admit({:build, target}, expected)

  def test_plugin(path, expected \\ Workbench.Session.identity()),
    do: admit({:plugin, :test, path}, expected)

  def package_plugin(path, expected \\ Workbench.Session.identity()),
    do: admit({:plugin, :package, path}, expected)

  def install_plugin(path, device, expected \\ Workbench.Session.identity()),
    do: admit({:install, path, device}, expected)

  def review_firmware(node, firmware, expected \\ Workbench.Session.identity()),
    do: admit({:review_firmware, node, firmware}, expected)

  def confirm_firmware(token, address, expected \\ Workbench.Session.identity()),
    do: admit({:confirm, :firmware, token, [address]}, expected)

  def confirm_plugin(token, address, expected \\ Workbench.Session.identity()),
    do: admit({:confirm, :plugin_install, token, [address]}, expected)

  def review_factory(params, expected \\ Workbench.Session.identity()),
    do: admit({:review_factory, params}, expected)

  def check(node, scenario, expected \\ Workbench.Session.identity()),
    do: admit({:check, node, scenario}, expected)

  def confirm_factory(token, text, identified, expected \\ Workbench.Session.identity()),
    do: admit({:confirm, :factory, token, [text, identified]}, expected)

  defp admit(request, expected), do: GenServer.call(__MODULE__, {:admit, expected, request})

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    session = Process.whereis(Workbench.SessionServices)

    restarted =
      not is_nil(session) and :persistent_term.get({__MODULE__, :session}, nil) == session

    if session, do: :persistent_term.put({__MODULE__, :session}, session)

    current =
      if restarted do
        %{
          view("maintenance", :uncertain)
          | certainty: :unknown,
            result:
              "Jobs owner restarted; operation history/effects are unknown. Inspect targets and coordinate session replacement; do not replay."
        }
      else
        view(nil, :idle)
      end

    {:ok, %{task: nil, review: nil, view: current, history: [], blocked: restarted}}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

  def handle_call(:history, _, state),
    do: {:reply, Enum.take([state.view | state.history], 21), state}

  def handle_call({:fetch, id}, _, state) do
    job = Enum.find([state.view | state.history], &(&1.id == id))

    {:reply,
     if(job, do: {:ok, job}, else: {:error, "Unknown job in this session; inspect mix dev.job"}),
     state}
  end

  def handle_call({:admit, expected, request}, from, state) do
    with :ok <- Workbench.Session.admit(expected) do
      handle_call(request, from, state)
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(_, _, %{blocked: true} = state),
    do:
      {:reply,
       {:error,
        "Maintenance outcome uncertain. Inspect the job and target; no further maintenance admitted in this session."},
       state}

  def handle_call(_, _, %{task: task} = state) when task != nil,
    do: {:reply, {:error, "Finish the current job first"}, state}

  def handle_call({:build, target}, _, state) when target in ["x86_64", "ec100"] do
    lifecycle = Scenarios.Runner.snapshot().lifecycle

    if target == "x86_64" and (lifecycle.status != :stopped or lifecycle.prepared),
      do:
        {:reply, {:error, "Reset and stop simulated devices before rebuilding QEMU firmware"},
         state},
      else: start(state, "firmware", target, &{:ok, Workbench.Builds.firmware!(target, &1)})
  end

  def handle_call({:build, _}, _, state), do: {:reply, {:error, "Choose EC100 or x86_64"}, state}

  def handle_call({:plugin, kind, path}, _, state) do
    run =
      case kind do
        :test ->
          fn report ->
            :ok = Workbench.Plugins.test!(path, report)
            {:ok, "Tests passed"}
          end

        :package ->
          &{:ok, Workbench.Plugins.package!(path, &1)}
      end

    start(state, Atom.to_string(kind), path, run)
  end

  def handle_call({:install, path, device}, _, state) do
    case Workbench.Gateways.fetch(device) do
      {:ok, %{source: :network} = gateway} ->
        start(
          state,
          "plugin_review",
          path,
          &{:review, Workbench.PluginInstall.review!(path, gateway.node, &1)}
        )

      {:ok, %{source: :qemu, sim_id: id}} ->
        start(state, "install", path, &{:ok, install_qemu!(path, id, &1)}, id)

      _ ->
        {:reply, {:error, "Choose an explicit connected gateway from mix gateway.list"}, state}
    end
  end

  def handle_call({:review_firmware, node, firmware}, _, state),
    do:
      start(
        state,
        "firmware_review",
        node,
        &{:review, Workbench.FirmwareUpdate.review!(node, firmware, &1)}
      )

  def handle_call({:check, node, id}, _, state) do
    with {:ok, %{source: :network} = gateway} <- Workbench.Gateways.fetch(node),
         %{} = scenario <- Enum.find(Scenarios.physical(), &(&1.id == id)) do
      start(state, "check", gateway.node, fn report ->
        Process.put(:scenario_report, report)
        result = Scenarios.run(scenario, %{device: %{node: gateway.node, physical: true}})

        if result.status == :passed,
          do: {:ok, "#{scenario.name}: passed"},
          else: {:error, "#{scenario.name}: #{result.status}. #{result.detail}"}
      end)
    else
      _ -> {:reply, {:error, "Choose a connected physical gateway and a physical check"}, state}
    end
  end

  def handle_call({:review_factory, params}, _, state),
    do:
      start(
        state,
        "factory_review",
        nil,
        &{:review, Workbench.FactoryProvisioning.review!(params, &1)}
      )

  def handle_call(
        {:confirm, kind, token, args},
        _,
        %{review: %{public: %{kind: kind}} = plan} = state
      ) do
    owner = plan.owner
    apply(owner, :confirmation!, [plan, token | args])

    {kind_name, run} =
      case kind do
        :firmware ->
          {"firmware_update", &Workbench.FirmwareUpdate.update!(plan, token, hd(args), &1)}

        :plugin_install ->
          {"install", &Workbench.PluginInstall.install!(plan, token, hd(args), &1)}

        :factory ->
          {"factory_provision", &{:ok, Workbench.FactoryProvisioning.provision!(plan, &1)}}
      end

    # Consumed exactly once: the worker owns the snapshot from here.
    case start(%{state | review: nil}, kind_name, state.view.subject, run) do
      {:reply, {:ok, id}, next} ->
        # Factory recovery files must stay visible whatever the outcome.
        recovery = if kind == :factory, do: plan.public.backup
        {:reply, {:ok, id}, publish(put_in(next.view.recovery, recovery))}

      {:reply, error, _} ->
        {:reply, error, state}
    end
  rescue
    error in ArgumentError -> {:reply, {:error, Exception.message(error)}, state}
  end

  def handle_call({:confirm, _, _, _}, _, state),
    do: {:reply, {:error, "Review first; another review cannot authorize this"}, state}

  @impl true
  def handle_info({:output, id, line}, %{view: %{id: id}} = state),
    do: {:noreply, publish(put_in(state.view.output, String.slice(line, 0, 2000)))}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:review, plan} ->
          Process.send_after(self(), {:expire, plan.public.token}, @ttl_ms)

          %{
            state
            | review: plan,
              view: %{
                state.view
                | status: :awaiting_confirmation,
                  certainty: :known,
                  review: plan.public
              }
          }

        {:ok, message} ->
          %{
            state
            | view: %{
                state.view
                | status: :succeeded,
                  certainty: :known,
                  result: to_string(message)
              }
          }

        {:error, message} ->
          # A maintenance exception/reply alone cannot prove no remote effects.
          uncertain = effectful?(state.view.kind)

          %{
            state
            | blocked: state.blocked or uncertain,
              view: %{
                state.view
                | status: if(uncertain, do: :uncertain, else: :failed),
                  certainty: if(uncertain, do: :unknown, else: :known),
                  result: message
              }
          }
      end

    {:noreply, publish(%{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state) do
    result =
      "Job worker exited. The outcome is unknown; inspect the device and preserve recovery files. Do not retry automatically."

    {:noreply,
     publish(%{
       state
       | task: nil,
         blocked: true,
         view: %{state.view | status: :uncertain, certainty: :unknown, result: result}
     })}
  end

  def handle_info({:expire, token}, %{review: %{public: %{token: token}} = plan} = state) do
    plan.owner.cleanup(plan)
    view = %{state.view | status: :failed, review: nil, result: "Review expired; review again"}
    {:noreply, publish(%{state | review: nil, view: view})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start(state, kind, subject, run, device \\ nil) do
    owner = self()

    id =
      "#{System.get_env("WORKBENCH_SESSION_ID", "local")}:jobs:#{System.unique_integer([:positive, :monotonic])}"

    task =
      Task.Supervisor.async(Workbench.Tasks, fn ->
        receive do
          :admitted ->
            try do
              run.(&send(owner, {:output, id, &1}))
            rescue
              error -> {:error, Exception.message(error)}
            end
        end
      end)

    reservation = if device, do: %{subject: subject, device: device}, else: subject

    case Scenarios.Runner.admit_job(task.pid, kind, reservation) do
      :ok ->
        if state.review, do: state.review.owner.cleanup(state.review)
        send(task.pid, :admitted)

        history =
          if state.view.id, do: Enum.take([state.view | state.history], 20), else: state.history

        current = %{view(kind, :running, subject) | id: id}

        {:reply, {:ok, id},
         publish(%{state | task: task, review: nil, history: history, view: current})}

      error ->
        Task.shutdown(task, :brutal_kill)
        {:reply, error, state}
    end
  end

  @impl true
  def terminate(_, state) do
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    if state.review, do: state.review.owner.cleanup(state.review)
  end

  defp view(kind, status, subject \\ nil),
    do: %{
      id: nil,
      certainty: if(status == :running, do: :pending, else: :known),
      next: "Inspect mix dev.job and the explicit target. Never replay an uncertain operation.",
      kind: kind,
      status: status,
      subject: subject,
      output: nil,
      result: nil,
      review: nil,
      recovery: nil
    }

  # Only this admitted Jobs worker packages and orchestrates the reserved install.
  defp install_qemu!(path, target, report) do
    output = Workbench.Plugins.package!(path, report, :temporary)
    {owner, _} = Scenarios.Runner.watch(self())
    monitor = Process.monitor(owner)

    try do
      case Scenarios.Runner.install(target, output) do
        {:ok, id} ->
          report.("Runner operation #{id}")

          await_install!(
            id,
            report,
            Scenarios.Runner.snapshot(),
            monitor,
            System.monotonic_time(:millisecond) + 600_000
          )

        {:error, message} ->
          raise ArgumentError, message
      end
    after
      Process.demonitor(monitor, [:flush])
      File.rm(output)
    end
  end

  defp await_install!(id, report, snapshot, monitor, deadline) do
    run = Enum.find(snapshot.runs, &(&1.id == id))
    if run, do: report.(run.phase)

    case run do
      %{status: :passed} ->
        "Plugin running"

      %{status: status} when status != :running ->
        raise "Installation #{status}; inspect runner operation #{id} before any retry"

      _ ->
        receive do
          {:scenarios, snapshot} ->
            await_install!(id, report, snapshot, monitor, deadline)

          {:DOWN, ^monitor, :process, _, _} ->
            raise "Install outcome unknown; inspect before retrying"
        after
          max(deadline - System.monotonic_time(:millisecond), 0) ->
            raise "Install wait deadline reached; inspect operation #{id}; do not retry"
        end
    end
  end

  defp effectful?(kind), do: kind in ["install", "firmware_update", "factory_provision", "check"]

  defp publish(state) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, @topic, {:jobs, state.view})
    state
  end
end

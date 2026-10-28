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
  def subscribe, do: Phoenix.PubSub.subscribe(NervesGate.PubSub, @topic)

  def build(target), do: GenServer.call(__MODULE__, {:build, target})
  def test_plugin(path), do: GenServer.call(__MODULE__, {:plugin, :test, path})
  def package_plugin(path), do: GenServer.call(__MODULE__, {:plugin, :package, path})
  def install_plugin(path, device), do: GenServer.call(__MODULE__, {:install, path, device})

  def review_firmware(node, firmware),
    do: GenServer.call(__MODULE__, {:review_firmware, node, firmware})

  def confirm_firmware(token, address),
    do: GenServer.call(__MODULE__, {:confirm, :firmware, token, [address]})

  def confirm_plugin(token, address),
    do: GenServer.call(__MODULE__, {:confirm, :plugin_install, token, [address]})

  def review_factory(params), do: GenServer.call(__MODULE__, {:review_factory, params})
  def check(node, scenario), do: GenServer.call(__MODULE__, {:check, node, scenario})

  def confirm_factory(token, text, identified),
    do: GenServer.call(__MODULE__, {:confirm, :factory, token, [text, identified]})

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)
    {:ok, %{task: nil, review: nil, view: view(nil, :idle)}}
  end

  @impl true
  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

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
          "install",
          path,
          &{:review, Workbench.PluginInstall.review!(path, gateway.node, &1)}
        )

      _ ->
        start(state, "install", path, &{:ok, Workbench.Plugins.install!(path, device, &1)})
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
      {:reply, :ok, next} ->
        # Factory recovery files must stay visible whatever the outcome.
        recovery = if kind == :factory, do: plan.public.backup
        {:reply, :ok, publish(put_in(next.view.recovery, recovery))}

      {:reply, error, _} ->
        {:reply, error, state}
    end
  rescue
    error in ArgumentError -> {:reply, {:error, Exception.message(error)}, state}
  end

  def handle_call({:confirm, _, _, _}, _, state),
    do: {:reply, {:error, "Review first; another review cannot authorize this"}, state}

  @impl true
  def handle_info({:output, line}, state),
    do: {:noreply, publish(put_in(state.view.output, line))}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    state =
      case result do
        {:review, plan} ->
          Process.send_after(self(), {:expire, plan.public.token}, @ttl_ms)

          %{
            state
            | review: plan,
              view: %{state.view | status: :awaiting_confirmation, review: plan.public}
          }

        {:ok, message} ->
          %{state | view: %{state.view | status: :succeeded, result: to_string(message)}}

        {:error, message} ->
          %{state | view: %{state.view | status: :failed, result: message}}
      end

    {:noreply, publish(%{state | task: nil})}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state) do
    result =
      "Job worker exited. The outcome is unknown; inspect the device and preserve recovery files. Do not retry automatically."

    {:noreply,
     publish(%{state | task: nil, view: %{state.view | status: :failed, result: result}})}
  end

  def handle_info({:expire, token}, %{review: %{public: %{token: token}} = plan} = state) do
    plan.owner.cleanup(plan)
    view = %{state.view | status: :failed, review: nil, result: "Review expired; review again"}
    {:noreply, publish(%{state | review: nil, view: view})}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp start(state, kind, subject, run) do
    owner = self()

    task =
      Task.Supervisor.async(Workbench.Tasks, fn ->
        receive do
          :admitted ->
            try do
              run.(&send(owner, {:output, &1}))
            rescue
              error -> {:error, Exception.message(error)}
            end
        end
      end)

    case Scenarios.Runner.admit_job(task.pid, kind, subject) do
      :ok ->
        if state.review, do: state.review.owner.cleanup(state.review)
        send(task.pid, :admitted)

        {:reply, :ok,
         publish(%{state | task: task, review: nil, view: view(kind, :running, subject)})}

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
      kind: kind,
      status: status,
      subject: subject,
      output: nil,
      result: nil,
      review: nil,
      recovery: nil
    }

  defp publish(state) do
    Phoenix.PubSub.broadcast(NervesGate.PubSub, @topic, {:jobs, state.view})
    state
  end
end

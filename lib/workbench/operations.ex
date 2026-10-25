defmodule Workbench.Operations do
  @moduledoc "Serialized workbench operations, including explicitly confirmed physical firmware updates."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  def start(kind, app \\ nil, device \\ nil),
    do: GenServer.call(__MODULE__, {:start, kind, app, device})

  def lifecycle(action), do: GenServer.call(__MODULE__, {:lifecycle, action})
  def stop_session(id), do: GenServer.call(__MODULE__, {:stop_session, id})
  def review_firmware(params), do: GenServer.call(__MODULE__, {:review_firmware, params})

  def review_app_install(project, address),
    do: GenServer.call(__MODULE__, {:review_app_install, project, address})

  def confirm_app_install(id, address, project),
    do: GenServer.call(__MODULE__, {:confirm_app_install, id, address, project})

  def confirm_firmware(id, address),
    do: GenServer.call(__MODULE__, {:confirm_firmware, id, address})

  def review_reboot(address, management \\ "ssh"),
    do: GenServer.call(__MODULE__, {:review_reboot, address, management})

  def confirm_reboot(id, address), do: GenServer.call(__MODULE__, {:confirm_reboot, id, address})
  def cancel_observation(address), do: GenServer.call(__MODULE__, {:cancel_observation, address})

  def review_factory(params), do: GenServer.call(__MODULE__, {:review_factory, params})

  def confirm_factory(id, text, identified),
    do: GenServer.call(__MODULE__, {:confirm_factory, id, text, identified})

  def init(_), do: {:ok, %{task: nil, review: nil, stopping: false, view: view(:idle, nil)}}
  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

  def handle_call(
        {:cancel_observation, address},
        _,
        %{task: %{pid: pid}, view: %{kind: kind, context: %{subject: address}}} = state
      )
      when kind in ["hardware_failover", "reboot_verify"] do
    send(pid, :cancel_hardware_observation)

    {:reply, :ok,
     %{
       state
       | view: %{
           state.view
           | output:
               "Cancellation requested. Wait for the bounded read to finish; restore Ethernet cables. Do not repeat a button action."
         }
     }}
  end

  def handle_call({:cancel_observation, _}, _, state),
    do:
      {:reply,
       {:error,
        "Only this device's active failover or reboot observation can be cancelled; writes cannot be cancelled here"},
       state}

  def handle_call(_, _, %{stopping: true} = state),
    do: {:reply, {:error, "The workbench session is stopping"}, state}

  def handle_call(_, _, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, "Finish the workbench operation first"}, state}

  def handle_call({:lifecycle, action}, _, state),
    do: {:reply, Scenarios.Runner.lifecycle(action), state}

  def handle_call({:stop_session, id}, {request, _}, state) do
    result = Scenarios.Runner.stop_session(id, request)
    state = if result == :ok, do: drop_review(state), else: state
    {:reply, result, %{state | stopping: result == :ok}}
  end

  def handle_call({:review_app_install, project, address}, _, state) do
    with :ok <- admitted("install", project), :ok <- admitted("device_info", address) do
      start_task(
        state,
        "app_install_review",
        fn report ->
          {:review, Workbench.PhysicalAppInstall.review!(project, address, report)}
        end,
        nil,
        %{subject: project, address: address}
      )
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:confirm_app_install, id, address, project},
        _,
        %{review: %{public: %{kind: :app_install, project: project}}} = state
      ) do
    try do
      :ok = Workbench.PhysicalAppInstall.confirmation!(state.review, id, address)
      plan = state.review

      start_task(
        %{state | review: nil},
        "app_install",
        fn report ->
          Workbench.PhysicalAppInstall.install!(plan, report)
        end,
        nil,
        %{subject: project, address: plan.public.address}
      )
    rescue
      error in ArgumentError -> {:reply, {:error, Exception.message(error)}, state}
    end
  end

  def handle_call({:confirm_app_install, _, _, _}, _, state),
    do: {:reply, {:error, "Review this application's physical install first"}, state}

  def handle_call({:review_firmware, params}, _, state) do
    start_task(
      state,
      "firmware_review",
      fn report ->
        plan = Workbench.FirmwareUpdate.review!(params, report)
        Workbench.LANDiscovery.record_identity(plan.public.address, plan.device)
        {:review, plan}
      end,
      nil,
      %{address: params["address"]}
    )
  end

  def handle_call({:review_reboot, address, management}, _, state) do
    with :ok <- admitted("device_info", address) do
      start_task(
        state,
        "reboot_review",
        fn _ ->
          {:review, Workbench.Hardware.review_reboot!(address, management)}
        end,
        nil,
        %{subject: address, device: nil}
      )
    else
      error -> {:reply, error, state}
    end
  end

  def handle_call(
        {:confirm_reboot, id, address},
        _,
        %{review: %{public: %{kind: :reboot}}} = state
      ) do
    try do
      :ok = Workbench.Hardware.confirm_reboot!(state.review, id, address)
      plan = state.review

      start_task(
        %{state | review: nil},
        "reboot_verify",
        fn report ->
          Workbench.Hardware.observe_reboot!(plan, report)
        end,
        nil,
        %{subject: plan.public.address, device: nil}
      )
    rescue
      error in ArgumentError -> {:reply, {:error, Exception.message(error)}, state}
    end
  end

  def handle_call({:confirm_reboot, _, _}, _, state),
    do: {:reply, {:error, "Review this device's reboot observation first"}, state}

  def handle_call({:review_factory, params}, _, state) do
    start_task(state, "factory_review", fn report ->
      {:review, Workbench.FactoryProvisioning.review!(params, report)}
    end)
  end

  def handle_call(
        {:confirm_factory, id, text, identified},
        _,
        %{review: %{public: %{kind: :factory}}} = state
      ) do
    try do
      :ok = Workbench.FactoryProvisioning.confirmation!(state.review, id, text, identified)
      plan = state.review
      owner = self()

      start_task(
        %{state | review: nil},
        "factory_provision",
        fn report ->
          message = Workbench.FactoryProvisioning.provision!(plan, report)
          send(owner, {:factory_verified, self(), message})
          connection = Workbench.FactoryConnection.wait(plan, report)
          {:factory_complete, message, connection}
        end,
        %{backup: plan.public.backup, backup_enabled: Map.get(plan.public, :backup_enabled, true)}
      )
    rescue
      error in ArgumentError -> {:reply, {:error, Exception.message(error)}, state}
    end
  end

  def handle_call({:confirm_factory, _, _, _}, _, state),
    do: {:reply, {:error, "Review factory provisioning first"}, state}

  def handle_call({:confirm_firmware, _, _}, _, %{review: %{public: %{kind: :factory}}} = state),
    do: {:reply, {:error, "This is a factory review, not an SSH update"}, state}

  def handle_call({:confirm_firmware, _, _}, _, %{review: %{public: %{kind: :reboot}}} = state),
    do: {:reply, {:error, "This is a reboot observation review, not a firmware update"}, state}

  def handle_call(
        {:confirm_firmware, _, _},
        _,
        %{review: %{public: %{kind: :app_install}}} = state
      ),
      do:
        {:reply, {:error, "This is an application install review, not a firmware update"}, state}

  def handle_call({:confirm_firmware, _, _}, _, %{review: nil} = state),
    do: {:reply, {:error, "Review the firmware and device first"}, state}

  def handle_call({:confirm_firmware, id, address}, _, state) do
    try do
      :ok = Workbench.FirmwareUpdate.confirmation!(state.review, id, address)
      plan = state.review
      # Consume the review exactly once. The worker owns its snapshot from here.
      start_task(
        %{state | review: nil},
        "firmware_update",
        fn report ->
          Workbench.FirmwareUpdate.update!(plan, report)
        end,
        nil,
        %{address: plan.public.address}
      )
    rescue
      error in ArgumentError -> {:reply, {:error, Exception.message(error)}, state}
    end
  end

  def handle_call({:start, "device_info", address, _}, _, state),
    do: start_device_info(state, address)

  def handle_call({:start, kind, app, device}, _, state) do
    with :ok <- admitted(kind, app) do
      start_task(
        state,
        kind,
        fn report ->
          result =
            case kind do
              "firmware" -> Workbench.Builds.firmware!(app || "x86_64", report)
              "find_usb" -> Workbench.Hardware.discover!()
              "hardware_test" -> Workbench.Hardware.run!(app, device)
              "hardware_failover" -> Workbench.Hardware.failover!(app, device, report)
              "hardware_diagnostics" -> Workbench.Hardware.diagnostics!(app)
              "test" -> Workbench.Applications.test!(app, report)
              "package" -> Workbench.Applications.package!(app, report)
              "install" -> Workbench.Applications.install!(app, device, report)
            end

          case kind do
            kind when kind in ["hardware_test", "hardware_failover"] -> {:hardware_checks, result}
            "hardware_diagnostics" -> {:diagnostics, result}
            _ -> {:ok, inspect(result)}
          end
        end,
        nil,
        %{
          subject: app,
          device:
            if(kind in ["hardware_test", "hardware_failover", "hardware_diagnostics"],
              do: nil,
              else: device
            )
        }
      )
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  # Discovery only requests reads; this owner still serializes them with builds and updates.
  # Never let a background observation consume an awaiting destructive review.
  def handle_cast(:read_discovered, %{task: nil, review: nil, stopping: false} = state) do
    case Enum.find(Workbench.LANDiscovery.snapshot().devices, &Workbench.Devices.needs_info?/1) do
      nil ->
        {:noreply, state}

      device ->
        case start_device_info(state, device.address) do
          {:reply, :ok, started} ->
            {:noreply, Map.put(started, :background_previous_view, state.view)}

          {:reply, {:error, _}, state} ->
            {:noreply, state}
        end
    end
  end

  def handle_cast(:read_discovered, state), do: {:noreply, state}

  defp start_device_info(state, address) do
    with :ok <- admitted("device_info", address) do
      :ok = Workbench.LANDiscovery.record_read(address, :reading)

      start_task(
        state,
        "device_info",
        fn _ ->
          {:ok, Workbench.Devices.read_info!(address)}
        end,
        nil,
        %{subject: address, device: nil}
      )
    else
      error -> {:reply, error, state}
    end
  end

  defp finish_info_read(state, view) do
    if state.view.kind == "device_info" do
      :ok =
        Workbench.LANDiscovery.record_read(
          state.view.context.subject,
          view.status,
          if(view.status == :failed, do: view.result)
        )
    end

    GenServer.cast(self(), :read_discovered)
    {previous, state} = Map.pop(state, :background_previous_view)
    %{state | task: nil, view: previous || view}
  end

  defp start_task(state, kind, run, recovery \\ nil, context \\ nil) do
    state = drop_review(state)
    owner = self()

    task =
      Task.Supervisor.async_nolink(Workbench.Tasks, fn ->
        try do
          run.(&send(owner, {:output, &1}))
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    view = view(:running, kind) |> Map.put(:recovery, recovery) |> Map.put(:context, context)
    {:reply, :ok, %{state | task: task, view: view}}
  end

  defp admitted("device_info", address) do
    if Enum.any?(Workbench.LANDiscovery.snapshot().devices, &(&1.address == address)),
      do: :ok,
      else: {:error, "Add the device address first"}
  end

  defp admitted("find_usb", _), do: :ok

  defp admitted(kind, address)
       when kind in ["hardware_test", "hardware_failover", "hardware_diagnostics"],
       do: admitted("device_info", address)

  defp admitted("firmware", "ec100"), do: :ok

  defp admitted("firmware", target) when target in [nil, "x86_64"] do
    lifecycle = Scenarios.Runner.snapshot().lifecycle

    if lifecycle.status == :stopped and not lifecycle.prepared,
      do: :ok,
      else: {:error, "Reset and stop simulated devices before rebuilding QEMU firmware"}
  end

  defp admitted("firmware", _), do: {:error, "Choose EC100 or x86_64 QEMU"}

  defp admitted(kind, path) when kind in ["test", "package", "install"] do
    if Enum.any?(Workbench.Applications.list(), &(&1.path == path)),
      do: :ok,
      else: {:error, "Create or open the application first"}
  end

  defp admitted(_, _), do: {:error, "Unknown workbench operation"}

  def handle_info({:output, line}, state),
    do: {:noreply, %{state | view: %{state.view | output: line}}}

  def handle_info({ref, {:review, plan}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    Process.send_after(
      self(),
      {:expire_review, plan.public.token},
      max(plan.expires - System.monotonic_time(:millisecond), 0)
    )

    {:noreply,
     %{
       state
       | task: nil,
         review: plan,
         view: %{
           state.view
           | status: :awaiting_confirmation,
             review: plan.public,
             result:
               case Map.get(plan.public, :kind) do
                 :factory ->
                   "Factory review complete. Transport loaded into RAM only; no eMMC writes."

                 :app_install ->
                   "Application install reviewed. No package uploaded or device changes made. Confirmation installs a new stopped app only."

                 :reboot ->
                   "Reboot observation reviewed. Do not press the button until observation is armed. No reboot command was sent."

                 _ ->
                   "Review complete. No firmware has been sent."
               end
         }
     }}
  end

  def handle_info({:factory_verified, pid, message}, %{task: %{pid: pid}} = state) do
    view =
      Map.merge(state.view, %{
        result: message,
        flash_verified: true,
        connection: %{status: :waiting}
      })

    {:noreply, %{state | view: view}}
  end

  def handle_info({:factory_verified, _, _}, state), do: {:noreply, state}

  def handle_info({ref, {:factory_complete, message, connection}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    view =
      Map.merge(state.view, %{
        status: :succeeded,
        result: message,
        flash_verified: true,
        connection: connection
      })

    {:noreply, finish_info_read(state, view)}
  end

  def handle_info({ref, {:diagnostics, report}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    view =
      Map.merge(state.view, %{
        status: :succeeded,
        diagnostic_report: report,
        result:
          "Sanitized diagnostic snapshot collected over verified SSH. No raw logs, credentials or SIM identifiers included."
      })

    {:noreply, finish_info_read(state, view)}
  end

  def handle_info({ref, {:hardware_checks, result}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    status = Scenarios.result(result.rows)

    view =
      Map.merge(state.view, %{
        status: if(status == :passed, do: :succeeded, else: :failed),
        checks: result,
        result:
          if(state.view.kind == "hardware_failover",
            do:
              "Operator-assisted backup failover: #{status}. Restore all Ethernet cables, including after failure or cancellation. No network configuration was changed.",
            else:
              "Read-only SSH readiness: #{status}. Configuration and failover transitions were not changed or exercised."
          )
      })

    {:noreply, finish_info_read(state, view)}
  end

  def handle_info({ref, {status, message}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    view =
      if Map.get(state.view, :flash_verified, false) and status != :ok do
        Map.merge(state.view, %{
          status: :succeeded,
          connection: %{
            status: :unavailable,
            message: "Flash verified; USB reconnect could not complete. No flash retry was made."
          }
        })
      else
        %{state.view | status: if(status == :ok, do: :succeeded, else: :failed), result: message}
      end

    {:noreply, finish_info_read(state, view)}
  end

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %{ref: ref}} = state) do
    view =
      if Map.get(state.view, :flash_verified, false) do
        Map.merge(state.view, %{
          status: :succeeded,
          connection: %{
            status: :unavailable,
            message:
              "Flash verified; USB reconnect worker exited (#{worker_exit(reason)}). No flash retry was made."
          }
        })
      else
        %{
          state.view
          | status: :failed,
            result:
              "Worker exited (#{worker_exit(reason)}). Operation outcome is unknown; inspect the device and preserve recovery files. Do not retry automatically."
        }
      end

    {:noreply, finish_info_read(state, view)}
  end

  def handle_info({:expire_review, id}, %{review: %{public: %{token: id}}} = state) do
    message =
      case Map.get(state.review.public, :kind) do
        :factory -> "Factory review expired; re-enter MASKROM before reviewing again"
        :reboot -> "Reboot observation review expired. Review again before pressing the button."
        :app_install -> "Application install review expired; review the package and device again"
        _ -> "Firmware review expired"
      end

    GenServer.cast(self(), :read_discovered)
    {:noreply, %{drop_review(state) | view: %{view(:idle, nil) | result: message}}}
  end

  def handle_info({:expire_review, _}, state), do: {:noreply, state}

  defp drop_review(state) do
    case state.review do
      %{public: %{kind: :factory}} = plan -> Workbench.FactoryProvisioning.cleanup(plan)
      %{public: %{kind: :reboot}} -> :ok
      %{public: %{kind: :app_install}} = plan -> Workbench.PhysicalAppInstall.cleanup(plan)
      plan -> Workbench.FirmwareUpdate.cleanup(plan)
    end

    %{state | review: nil, view: %{state.view | review: nil}}
  end

  # Report a fixed diagnostic category, never arbitrary exit terms or arguments.
  defp worker_exit(:epipe), do: "broken subprocess pipe: epipe"
  defp worker_exit(:killed), do: "killed"
  defp worker_exit(:shutdown), do: "shutdown"
  defp worker_exit({:shutdown, _}), do: "shutdown"
  defp worker_exit(:normal), do: "normal exit without a result"
  defp worker_exit(:timeout), do: "timeout"
  defp worker_exit({:timeout, _}), do: "timeout"
  defp worker_exit(_), do: "unexpected termination"

  defp view(status, kind),
    do: %{
      status: status,
      kind: kind,
      output: nil,
      result: nil,
      review: nil,
      recovery: nil,
      connection: nil,
      flash_verified: false
    }
end

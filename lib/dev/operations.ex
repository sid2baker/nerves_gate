defmodule Dev.Operations do
  @moduledoc "Serialized workbench operations, including explicitly confirmed physical firmware updates."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  def start(kind, app \\ nil, device \\ nil),
    do: GenServer.call(__MODULE__, {:start, kind, app, device})

  def lifecycle(action), do: GenServer.call(__MODULE__, {:lifecycle, action})
  def stop_session(id), do: GenServer.call(__MODULE__, {:stop_session, id})
  def review_firmware(params), do: GenServer.call(__MODULE__, {:review_firmware, params})

  def confirm_firmware(id, address),
    do: GenServer.call(__MODULE__, {:confirm_firmware, id, address})

  def init(_), do: {:ok, %{task: nil, review: nil, stopping: false, view: view(:idle, nil)}}
  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

  def handle_call(_, _, %{stopping: true} = state),
    do: {:reply, {:error, "The workbench session is stopping"}, state}

  def handle_call(_, _, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, "Finish the workbench operation first"}, state}

  def handle_call({:lifecycle, action}, _, state),
    do: {:reply, NervesGateSim.QemuTests.lifecycle(action), state}

  def handle_call({:stop_session, id}, {request, _}, state) do
    result = NervesGateSim.QemuTests.stop_session(id, request)
    state = if result == :ok, do: drop_review(state), else: state
    {:reply, result, %{state | stopping: result == :ok}}
  end

  def handle_call({:review_firmware, params}, _, state) do
    start_task(state, "firmware_review", fn report ->
      {:review, Dev.FirmwareUpdate.review!(params, report)}
    end)
  end

  def handle_call({:confirm_firmware, _, _}, _, %{review: nil} = state),
    do: {:reply, {:error, "Review the firmware and device first"}, state}

  def handle_call({:confirm_firmware, id, address}, _, state) do
    try do
      :ok = Dev.FirmwareUpdate.confirmation!(state.review, id, address)
      plan = state.review
      # Consume the review exactly once. The worker owns its snapshot from here.
      start_task(%{state | review: nil}, "firmware_update", fn report ->
        {:ok, Dev.FirmwareUpdate.update!(plan, report)}
      end)
    rescue
      error in ArgumentError -> {:reply, {:error, Exception.message(error)}, state}
    end
  end

  def handle_call({:start, kind, app, device}, _, state) do
    with :ok <- admitted(kind, app) do
      start_task(state, kind, fn report ->
        result =
          case kind do
            "firmware" -> Dev.Builds.firmware!(app || "x86_64", report)
            "test" -> Dev.Applications.test!(app, report)
            "package" -> Dev.Applications.package!(app, report)
            "install" -> Dev.Applications.install!(app, device, report)
          end

        {:ok, inspect(result)}
      end)
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp start_task(state, kind, run) do
    state = drop_review(state)
    owner = self()

    task =
      Task.Supervisor.async_nolink(Dev.Tasks, fn ->
        try do
          run.(&send(owner, {:output, &1}))
        rescue
          error -> {:error, Exception.message(error)}
        end
      end)

    {:reply, :ok, %{state | task: task, view: view(:running, kind)}}
  end

  defp admitted("firmware", "ec100"), do: :ok

  defp admitted("firmware", target) when target in [nil, "x86_64"] do
    lifecycle = NervesGateSim.QemuTests.snapshot().lifecycle

    if lifecycle.status == :stopped and not lifecycle.prepared,
      do: :ok,
      else: {:error, "Reset and stop simulated devices before rebuilding QEMU firmware"}
  end

  defp admitted("firmware", _), do: {:error, "Choose EC100 or x86_64 QEMU"}

  defp admitted(kind, path) when kind in ["test", "package", "install"] do
    if Enum.any?(Dev.Applications.list(), &(&1.path == path)),
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
             result: "Review complete. No firmware has been sent."
         }
     }}
  end

  def handle_info({ref, {status, message}}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    {:noreply,
     %{
       state
       | task: nil,
         view: %{
           state.view
           | status: if(status == :ok, do: :succeeded, else: :failed),
             result: message
         }
     }}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %{ref: ref}} = state),
    do:
      {:noreply,
       %{
         state
         | task: nil,
           view: %{
             state.view
             | status: :failed,
               result: "Worker exited; inspect the operation/device before retrying"
           }
       }}

  def handle_info({:expire_review, id}, %{review: %{public: %{token: id}}} = state),
    do:
      {:noreply,
       %{drop_review(state) | view: %{view(:idle, nil) | result: "Firmware review expired"}}}

  def handle_info({:expire_review, _}, state), do: {:noreply, state}

  defp drop_review(state) do
    Dev.FirmwareUpdate.cleanup(state.review)
    %{state | review: nil, view: %{state.view | review: nil}}
  end

  defp view(status, kind),
    do: %{status: status, kind: kind, output: nil, result: nil, review: nil}
end

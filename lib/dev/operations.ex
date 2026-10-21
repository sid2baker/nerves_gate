defmodule Dev.Operations do
  @moduledoc "One supervised workbench build/app operation at a time, with observable progress."
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  def snapshot, do: GenServer.call(__MODULE__, :snapshot)

  def start(kind, app \\ nil, device \\ nil),
    do: GenServer.call(__MODULE__, {:start, kind, app, device})

  def lifecycle(action), do: GenServer.call(__MODULE__, {:lifecycle, action})
  def stop_session(id), do: GenServer.call(__MODULE__, {:stop_session, id})

  def init(_),
    do:
      {:ok,
       %{task: nil, stopping: false, view: %{status: :idle, kind: nil, output: nil, result: nil}}}

  def handle_call(:snapshot, _, state), do: {:reply, state.view, state}

  def handle_call(_, _, %{stopping: true} = state),
    do: {:reply, {:error, "The workbench session is stopping"}, state}

  def handle_call(_, _, %{task: task} = state) when not is_nil(task),
    do: {:reply, {:error, "Finish the workbench operation first"}, state}

  def handle_call({:lifecycle, action}, _, state),
    do: {:reply, NervesGateSim.QemuTests.lifecycle(action), state}

  def handle_call({:stop_session, id}, {request, _}, state) do
    result = NervesGateSim.QemuTests.stop_session(id, request)
    {:reply, result, %{state | stopping: result == :ok}}
  end

  def handle_call({:start, kind, app, device}, _, state) do
    # Admission and lifecycle requests share this mailbox: a Start click cannot
    # race the stopped-state check and a firmware build accepted here.
    with :ok <- admitted(kind) do
      owner = self()

      task =
        Task.Supervisor.async_nolink(Dev.Tasks, fn ->
          report = &send(owner, {:output, &1})

          try do
            result =
              case kind do
                "firmware" -> Dev.Builds.firmware!(report)
                "test" -> Dev.Solution.test!(Dev.Solution.current!(), app, report)
                "package" -> Dev.Solution.package!(Dev.Solution.current!(), app, report)
                "install" -> Dev.Solution.install!(Dev.Solution.current!(), app, device, report)
              end

            {:ok, inspect(result)}
          rescue
            error -> {:error, Exception.message(error)}
          end
        end)

      view = %{status: :running, kind: kind, output: nil, result: nil}
      {:reply, :ok, %{state | task: task, view: view}}
    else
      {:error, _} = error -> {:reply, error, state}
    end
  end

  defp admitted("firmware") do
    lifecycle = NervesGateSim.QemuTests.snapshot().lifecycle

    if lifecycle.status == :stopped and not lifecycle.prepared,
      do: :ok,
      else: {:error, "Reset and stop simulated devices before rebuilding firmware"}
  end

  defp admitted(kind) when kind in ["test", "package", "install"] do
    if Dev.Workbench.solution(),
      do: :ok,
      else: {:error, "Open a solution with mix dev PATH first"}
  end

  defp admitted(_), do: {:error, "Unknown workbench operation"}

  def handle_info({:output, line}, state),
    do: {:noreply, %{state | view: %{state.view | output: line}}}

  def handle_info({ref, result}, %{task: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {status, message} = result

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

  def handle_info({:DOWN, ref, :process, _, reason}, %{task: %{ref: ref}} = state),
    do:
      {:noreply,
       %{
         state
         | task: nil,
           view: %{state.view | status: :failed, result: "Worker exited: #{inspect(reason)}"}
       }}
end

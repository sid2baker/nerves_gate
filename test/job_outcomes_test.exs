defmodule Workbench.JobOutcomesTest do
  use ExUnit.Case, async: false
  alias Workbench.Jobs

  setup do
    start_supervised!({Phoenix.PubSub, name: NervesGate.PubSub})
    :ok
  end

  test "maintenance errors remain uncertain and cannot admit another write" do
    state = running("firmware_update")
    ref = state.task.ref
    {:noreply, state} = Jobs.handle_info({ref, {:error, "Reply lost"}}, state)
    assert state.view.status == :uncertain
    assert state.view.certainty == :unknown
    assert state.blocked

    assert {:reply, {:error, _}, ^state} =
             Jobs.handle_call({:build, "ec100"}, {self(), make_ref()}, state)

    assert {:reply, {:ok, job}, ^state} =
             Jobs.handle_call({:fetch, state.view.id}, {self(), make_ref()}, state)

    assert job == state.view
  end

  test "a failed read-only review is not an uncertain upload" do
    state = running("firmware_review")
    ref = state.task.ref

    {:noreply, state} =
      Jobs.handle_info({ref, {:error, "Artifact conflict; no firmware sent"}}, state)

    assert state.view.status == :failed
    assert state.view.certainty == :known
    refute state.blocked
  end

  test "worker crash never fabricates a known failure" do
    state = running("install")
    ref = state.task.ref
    {:noreply, state} = Jobs.handle_info({:DOWN, ref, :process, self(), :killed}, state)
    assert state.view.status == :uncertain
    assert state.view.certainty == :unknown
    assert state.blocked
  end

  test "late output cannot overwrite a different operation" do
    state = running("firmware_review")
    assert {:noreply, ^state} = Jobs.handle_info({:output, "old-job", "late"}, state)
  end

  defp running(kind) do
    {:ok, state} = Jobs.init(nil)

    %{
      state
      | task: %{ref: make_ref()},
        view: %{state.view | id: "test:jobs:1", kind: kind, status: :running}
    }
  end
end

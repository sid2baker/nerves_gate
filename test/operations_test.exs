defmodule Dev.OperationsTest do
  use ExUnit.Case, async: true

  test "busy and stopping admission rejects operations, lifecycle and session shutdown" do
    {:ok, idle} = Dev.Operations.init(nil)
    from = {self(), make_ref()}

    for state <- [%{idle | task: %{ref: make_ref()}}, %{idle | stopping: true}] do
      for request <- [
            {:start, "firmware", nil, nil},
            {:start, "install", "sample", "gateway_a"},
            {:start, "device_info", "ec100.example.ts.net", nil},
            {:lifecycle, "start"},
            {:lifecycle, "reset"},
            {:stop_session, "session"}
          ] do
        assert {:reply, {:error, _}, ^state} = Dev.Operations.handle_call(request, from, state)
      end

      assert {:reply, view, ^state} = Dev.Operations.handle_call(:snapshot, from, state)
      assert view == state.view
    end
  end

  test "unknown workbench operations never start a worker" do
    {:ok, idle} = Dev.Operations.init(nil)

    assert {:reply, {:error, _}, ^idle} =
             Dev.Operations.handle_call({:start, "publish", nil, nil}, {self(), make_ref()}, idle)
  end
end

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
            {:review_factory, %{}},
            {:confirm_factory, "token", "ERASE EC100 101", "true"},
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

  test "factory and SSH confirmations cannot consume each other's reviews" do
    {:ok, idle} = Dev.Operations.init(nil)
    from = {self(), make_ref()}

    assert {:reply, {:error, _}, ^idle} =
             Dev.Operations.handle_call({:confirm_factory, "id", "text", "true"}, from, idle)

    ssh = %{idle | review: %{public: %{address: "ec100.local"}}}

    assert {:reply, {:error, _}, ^ssh} =
             Dev.Operations.handle_call({:confirm_factory, "id", "text", "true"}, from, ssh)

    factory = %{
      idle
      | review: %{
          public: %{kind: :factory, token: "id", confirmation: "ERASE EC100 101"},
          expires: System.monotonic_time(:millisecond) + 60_000
        }
    }

    assert {:reply, {:error, _}, ^factory} =
             Dev.Operations.handle_call({:confirm_firmware, "id", "ec100.local"}, from, factory)

    assert {:reply, {:error, _}, ^factory} =
             Dev.Operations.handle_call(
               {:confirm_factory, "wrong-id", "ERASE EC100 101", "true"},
               from,
               factory
             )
  end

  @tag :tmp_dir
  test "factory expiry drops only the snapshot and never a retained backup", %{tmp_dir: root} do
    {:ok, idle} = Dev.Operations.init(nil)
    dir = Path.join(root, "snapshot")
    backup = Path.join(root, "backup")
    File.mkdir!(dir)
    File.mkdir!(backup)
    plan = %{dir: dir, public: %{kind: :factory, token: "token", backup: backup}}
    state = %{idle | review: plan, view: %{idle.view | review: plan.public}}
    assert {:noreply, ^state} = Dev.Operations.handle_info({:expire_review, "old-token"}, state)
    assert {:noreply, expired} = Dev.Operations.handle_info({:expire_review, "token"}, state)
    assert expired.review == nil
    assert expired.view.review == nil
    assert expired.view.result =~ "MASKROM"
    refute File.exists?(dir)
    assert File.dir?(backup)
  end

  test "unknown workbench operations never start a worker" do
    {:ok, idle} = Dev.Operations.init(nil)

    assert {:reply, {:error, _}, ^idle} =
             Dev.Operations.handle_call({:start, "publish", nil, nil}, {self(), make_ref()}, idle)
  end
end

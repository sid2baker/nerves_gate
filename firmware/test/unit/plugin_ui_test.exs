defmodule NervesGate.PluginUITest do
  use ExUnit.Case, async: false
  alias NervesGate.Plugins
  alias NervesGate.Plugins.{Owner, UI}

  defmodule Component do
    use Phoenix.LiveComponent
    def render(assigns), do: ~H"<p>App-owned controls</p>"
  end

  setup do
    unless Process.whereis(UI), do: start_supervised!(UI)
    Owner.init()

    artifact = %{
      app: :ui_fixture,
      version: "1.0.0",
      apps: [%{app: :ui_fixture, env: [nerves_gate_ui: Component]}],
      modules: [Component]
    }

    owner = Owner.bind(artifact, {make_ref(), 1})
    activation = %{artifact: artifact, owner: owner, phase: :running, ui: Component}

    %{
      artifact: artifact,
      state: %{blocked: nil, job: nil, running: %{"ui_fixture" => activation}}
    }
  end

  test "only the verified optional LiveComponent is accepted", %{artifact: artifact} do
    assert {:ok, Component} = UI.component(artifact)
    assert {:ok, nil} = UI.component(put_in(artifact.apps, [%{app: :ui_fixture, env: []}]))
    assert {:error, :invalid_app_ui} = UI.component(%{artifact | modules: []})

    assert {:error, :invalid_app_ui} =
             UI.component(
               put_in(artifact.apps, [%{app: :ui_fixture, env: [nerves_gate_ui: __MODULE__]}])
             )
  end

  test "mount admission requires an idle running activation and preserves the caller PID", %{
    state: state
  } do
    assert {:reply, {:ok, Component, manager}, ^state} =
             Plugins.handle_call({:mount_ui, "ui_fixture"}, {self(), make_ref()}, state)

    assert manager == self()
    assert :pg.get_local_members(UI, "ui_fixture") == [self()]
    :ok = :pg.leave(UI, "ui_fixture", self())

    for unavailable <- [
          %{state | blocked: :cleanup_pending},
          %{state | job: %{op: make_ref()}},
          put_in(state.running["ui_fixture"].phase, :quiescing),
          put_in(state.running["ui_fixture"].ui, nil)
        ] do
      assert {:reply, {:error, :ui_unavailable}, ^unavailable} =
               Plugins.handle_call({:mount_ui, "ui_fixture"}, {self(), make_ref()}, unavailable)
    end

    Owner.quiesce(state.running["ui_fixture"].owner)

    assert {:reply, {:error, :ui_unavailable}, ^state} =
             Plugins.handle_call({:mount_ui, "ui_fixture"}, {self(), make_ref()}, state)
  end

  test "cleanup waits for all local UI processes to exit, even after the registering controller exits" do
    parent = self()

    manager =
      spawn(fn ->
        for app <- ["one", "two"] do
          pid =
            spawn(fn ->
              receive do
                :plugin_ui_close -> :ok
              end
            end)

          :ok = UI.join(app, pid)
          send(parent, {:session, pid})
        end
      end)

    ref = Process.monitor(manager)
    assert_receive {:session, one}
    assert_receive {:session, two}
    assert_receive {:DOWN, ^ref, :process, ^manager, _}
    assert :ok = UI.close_all()
    refute Process.alive?(one)
    refute Process.alive?(two)
    # :pg processes its own DOWN independently; the contract is confirmed death,
    # not synchronous delivery of the same monitor signal to another process.
    refute Enum.any?(:pg.get_local_members(UI, "one"), &Process.alive?/1)
  end

  test "a session that cannot detach blocks cleanup instead of being force-killed" do
    pid =
      spawn(fn ->
        receive do
          :release -> :ok
        end
      end)

    try do
      :ok = UI.join("busy", pid)
      assert {:error, :ui_cleanup_pending} = UI.close("busy")
      assert Process.alive?(pid)
    after
      send(pid, :release)
    end

    assert :ok = UI.close("busy")
  end
end

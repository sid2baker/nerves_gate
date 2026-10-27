defmodule Scenarios.Cases.AppUI do
  @moduledoc false
  import ExUnit.Assertions
  alias Scenarios.{Device, ManagedApp}

  def spec do
    %{
      name: "App-owned UI admission and checked session cleanup",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }
  end

  def run(%{device: vm}) do
    ManagedApp.with_app(vm, fn main ->
      archive =
        Workbench.Applications.package!(
          Path.join(Workbench.root(), "apps/tailnet_subrouter"),
          fn _ -> :ok end,
          :temporary
        )

      guest = "/tmp/subrouter-ui-#{Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)}.ez"

      try do
        assert :ok = Device.rpc(vm, File, :write, [guest, File.read!(archive)])
        assert {:ok, _} = ManagedApp.apps(vm, :install, [guest])

        assert {:error, :ui_unavailable} =
                 Device.rpc(vm, NervesGate.Apps, :mount_ui, ["tailnet_subrouter"])

        assert :ok = ManagedApp.apps(vm, :start, [:tailnet_subrouter])
        assert Device.rpc(vm, TailnetSubrouter, :status) == %{state: :disabled}
        {:ok, entries} = ManagedApp.apps(vm, :list, [])
        assert Enum.find(entries, &(&1.app == "tailnet_subrouter")).ui?
        response = Req.get!(Scenarios.Qemu.ui_url(vm) <> "/apps", retry: false)
        assert response.status == 200
        assert response.body =~ "/apps/tailnet_subrouter"

        client = ManagedApp.client(vm)

        assert {:ok, TailnetSubrouter.UI, _} =
                 ManagedApp.call(vm, client, NervesGate.Apps, :mount_ui, ["tailnet_subrouter"])

        assert :ok = ManagedApp.apps(vm, :stop, [:tailnet_subrouter])
        refute Device.rpc(vm, :erlang, :is_process_alive, [client])

        Device.await(vm, "closed app pages leave their local process group", fn _ ->
          Device.rpc(vm, :pg, :get_local_members, [NervesGate.Apps.UI, "tailnet_subrouter"]) == []
        end)

        assert ManagedApp.main(vm) == main
        assert Device.rpc(vm, :code, :is_loaded, [TailnetSubrouter.UI]) == false

        assert {:error, :ui_unavailable} =
                 Device.rpc(vm, NervesGate.Apps, :mount_ui, ["tailnet_subrouter"])

        assert :ok = ManagedApp.apps(vm, :start, [:tailnet_subrouter])
        assert Device.rpc(vm, TailnetSubrouter, :status) == %{state: :disabled}
      after
        assert :ok = ManagedApp.apps(vm, :uninstall, [:tailnet_subrouter])
        Device.rpc(vm, File, :rm, [guest])
        File.rm(archive)
      end
    end)
  end
end

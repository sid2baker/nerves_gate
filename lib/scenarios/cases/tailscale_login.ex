defmodule Scenarios.Cases.TailscaleLogin do
  @moduledoc false

  import ExUnit.Assertions

  import Scenarios.Device

  alias Scenarios.Qemu, as: Qemu

  def spec,
    do: %{
      name: "Tailscale obtains a private login link and defers HTTPS until enrollment",
      fresh_disk: true,
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    Qemu.check_firewall(vm)
    save(vm, settings("eth0"))
    Scenarios.Device.await(vm, "public Internet reachable", &internet?/1, 60_000)

    ready =
      Scenarios.Device.await(vm, "Tailscale daemon ready", & &1.actions["remote.connect"].enabled)

    # Remote itself rejects a draft based on another hostname, before any daemon write.
    stale = [expected: "not-#{ready.remote.hostname}"]

    assert {:error, %{code: "stale_remote"}} =
             Scenarios.Device.rpc(vm, NervesGate.Remote, :connect, ["nerves-gate-qemu", stale])

    assert {:error, %{code: "stale_remote"}} =
             Scenarios.Device.rpc(vm, NervesGate.Remote, :configure, ["nerves-gate-qemu", stale])

    assert Scenarios.Device.status(vm).remote.operation == nil
    # A deliberately invalid, non-secret key exercises the actual daemon path.
    key = "tskey-auth-qemu-invalid"

    assert :ok =
             Scenarios.Device.rpc(vm, NervesGate.Remote, :connect, [
               "nerves-gate-qemu",
               [auth_key: key]
             ])

    rejected =
      Scenarios.Device.await(
        vm,
        "invalid auth key rejected",
        fn status ->
          status.remote.operation == nil and status.remote.error != nil
        end,
        45_000
      )

    assert rejected.remote.auth_state == "error"
    assert rejected.remote.error.code == "remote_failed"
    refute Jason.encode!(rejected) =~ key
    refute inspect(Scenarios.Device.rpc(vm, Tailscaled, :get_configuration, [], 5_000)) =~ key
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.Remote, :connect, ["nerves-gate-qemu"])

    status =
      Scenarios.Device.await(
        vm,
        "Tailscale control server returned a private login link",
        fn status ->
          status.remote.operation == nil && Scenarios.Qemu.login_ready?(vm)
        end,
        45_000
      )

    assert status.remote.error == nil
    assert status.remote.auth_state != "authenticated"
    assert_remote_sign_in(vm)

    # Real unenrolled daemon: no listener is written before a usable identity.
    before = Scenarios.Device.rpc(vm, Tailscaled, :get_configuration, [], 5_000)
    assert before.serve == []
    assert :ok = Scenarios.Device.rpc(vm, Tailscaled, :refresh_configuration, [], 5_000)
    assert Scenarios.Device.rpc(vm, Tailscaled, :get_configuration, [], 5_000) == before

    assert {:error, :serve_not_ready} =
             Scenarios.Device.rpc(
               vm,
               NervesGate.Remote.Tailscaled,
               :execute,
               [:serve, %{dns_name: "not-enrolled.example.ts.net"}],
               5_000
             )

    assert Scenarios.Device.rpc(vm, Tailscaled, :get_configuration, [], 5_000) == before
    assert :ok = Scenarios.Device.rpc(vm, NervesGate.Remote, :disconnect, [])
    Scenarios.Device.await(vm, "Tailscale disconnect completed", &is_nil(&1.remote.operation))
  end

  alias NervesGateWeb.TailscaleLive
  alias Phoenix.LiveView.{Socket, Lifecycle}

  defp assert_remote_sign_in(vm) do
    # Run the actual gateway callbacks on their device, never through a host-side
    # command proxy. Only boolean assertions may mention private callback results.
    projection_state =
      NervesGate.ProjectionServer.snapshot({NervesGate.ProjectionServer, vm.node})

    raw =
      %Socket{private: %{lifecycle: %Lifecycle{}, live_temp: %{}}}
      |> Phoenix.LiveView.clear_flash()

    {:ok, observer} = Scenarios.Device.rpc(vm, TailscaleLive, :mount, [%{}, %{}, raw])

    observer =
      Phoenix.Component.assign(observer,
        projection_state: projection_state,
        projection: projection_state.status
      )

    projection = observer.assigns.projection
    previous = put_in(projection.remote.operation, "connect")

    requester =
      Phoenix.Component.assign(observer,
        projection: previous,
        request: :connect,
        login_requested: true
      )

    disconnected =
      Scenarios.Device.rpc(vm, TailscaleLive, :refresh_observations, [
        requester,
        NervesGate.Projection.disconnected().status
      ])

    private = disconnected.assigns.login_url == nil and not disconnected.assigns.login_open
    assert private

    ready =
      Scenarios.Device.rpc(vm, TailscaleLive, :refresh_observations, [requester, projection])

    url = ready.assigns.login_url

    # Only assert booleans here: failed assertions must not print the private URL/HTML.
    available = is_binary(url) and ready.assigns.login_open and ready.assigns.request == nil
    assert available
    page = remote_page(ready)
    link = Floki.find(page, "#tailscale-login-dialog[role='dialog'] #tailscale-login-link")
    linked = Floki.attribute(link, "href") == [url] and Floki.text(link) == url
    assert linked

    safe =
      :binary.match(
        :erlang.term_to_binary(Map.take(ready.assigns, [:projection, :flash, :form])),
        url
      ) == :nomatch

    assert safe

    {:noreply, closed} =
      Scenarios.Device.rpc(vm, TailscaleLive, :handle_event, ["close-login", %{}, ready])

    # Another changed observation rechecks the same URL without reopening the popup.
    changed = put_in(projection.remote.version, "changed-observation")
    closed = Scenarios.Device.rpc(vm, TailscaleLive, :refresh_observations, [closed, changed])
    refute closed.assigns.login_open

    {:noreply, reopened} =
      Scenarios.Device.rpc(vm, TailscaleLive, :handle_event, ["show-login", %{}, closed])

    assert reopened.assigns.login_open

    observer = Scenarios.Device.rpc(vm, TailscaleLive, :refresh_observations, [observer, changed])
    assert observer.assigns.login_url == nil
    refute observer.assigns.login_open

    online = %{
      projection
      | remote: %{projection.remote | state: "online", auth_state: "authenticated"}
    }

    connected = Scenarios.Device.rpc(vm, TailscaleLive, :refresh_observations, [reopened, online])
    assert connected.assigns.login_url == nil
    refute connected.assigns.login_open
    assert Phoenix.Flash.get(connected.assigns.flash, :info) == "Connected to Tailscale."
  end

  defp remote_page(socket) do
    socket.assigns
    |> TailscaleLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
    |> Floki.parse_document!()
  end
end

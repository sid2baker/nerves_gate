defmodule NervesGateWeb.RemoteLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias NervesGate.Remote
  @endpoint NervesGateWeb.Endpoint

  defmodule Adapter do
    @behaviour NervesGate.Remote.Adapter
    def snapshot(agent), do: Agent.get(agent, & &1.snapshot)
    def login_url(agent), do: Agent.get(agent, & &1.url)

    def execute(:connect, %{hostname: name}, agent) do
      state = Agent.get(agent, & &1)
      Process.sleep(Map.get(state, :delay, 0))

      case Map.get(state, :result, :ok) do
        :ok ->
          Agent.update(agent, fn state ->
            %{
              state
              | url: "https://login.tailscale.com/a/private-token",
                snapshot: %{state.snapshot | hostname: name, auth_state: "authenticating"}
            }
          end)

          {:ok, "https://login.tailscale.com/a/private-token"}

        error ->
          error
      end
    end

    def execute(:configure, %{hostname: name}, agent),
      do: Agent.update(agent, &put_in(&1.snapshot.hostname, name))

    def execute(:disconnect, _, agent) do
      Agent.update(
        agent,
        &%{&1 | url: nil, snapshot: %{&1.snapshot | state: "offline", auth_state: "stopped"}}
      )
    end

    def execute(operation, params, agent)
        when operation in [:sharing_enable, :sharing_disable, :sharing_sync] do
      {:ok, routes} =
        Remote.Sharing.change(operation, params, snapshot(agent).advertised_routes)

      Agent.update(agent, &put_in(&1.snapshot.advertised_routes, routes))
      {:ok, routes}
    end
  end

  setup do
    Supervisor.terminate_child(NervesGate.Supervisor, NervesGate.Network)
    Supervisor.terminate_child(NervesGate.Supervisor, Remote)
    NervesGate.Network.Host.reset()
    adapter = start_supervised!({Agent, fn -> %{snapshot: Remote.Host.defaults(), url: nil} end})
    start_supervised!({Remote, adapter: {Adapter, adapter}, poll_ms: 10})
    start_supervised!({NervesGate.Network, poll_ms: 10})
    NervesGate.status()

    on_exit(fn ->
      NervesGate.Network.Host.reset()
      Supervisor.restart_child(NervesGate.Supervisor, NervesGate.Network)
      Supervisor.restart_child(NervesGate.Supervisor, Remote)
    end)

    %{adapter: adapter}
  end

  test "connect, private sign-in link, approval, live connection, rename and explicit disconnect",
       ctx do
    {:ok, view, html} = live(build_conn(), "/settings/tailscale")
    assert html =~ "Tailscale"
    assert has_element?(view, "#remote_hostname[value=nerves-gate]")
    refute has_element?(view, "#tailscale-login-link")
    view |> form("#tailscale-form", remote: %{hostname: "my-gateway"}) |> render_submit()
    eventually(fn -> has_element?(view, "#tailscale-login-link") end)

    assert has_element?(
             view,
             "#tailscale-login-link[href='https://login.tailscale.com/a/private-token'][rel='noopener noreferrer'][referrerpolicy=no-referrer]"
           )

    refute Jason.encode!(NervesGate.status()) =~ "private-token"
    Agent.update(ctx.adapter, &put_in(&1.snapshot.auth_state, "needs_approval"))
    eventually(fn -> render(view) =~ "Waiting for approval" end)
    refute has_element?(view, "#tailscale-login-link")

    Agent.update(
      ctx.adapter,
      &%{
        &1
        | url: nil,
          snapshot:
            Map.merge(&1.snapshot, %{
              state: "online",
              auth_state: "authenticated",
              ipv4: "100.64.1.2"
            })
      }
    )

    eventually(fn -> render(view) =~ "100.64.1.2" end)
    assert has_element?(view, "#tailscale-save", "Save device name")
    refute render(view) =~ "Remote access ready"
    view |> form("#tailscale-form", remote: %{hostname: "renamed-gateway"}) |> render_submit()
    eventually(fn -> Agent.get(ctx.adapter, & &1.snapshot.hostname) == "renamed-gateway" end)
    view |> element("button", "Disconnect") |> render_click()
    assert render(view) =~ "you’ll lose this page"
    assert render(view) =~ "Enrollment and settings are kept"
    view |> element("button", "Cancel") |> render_click()
    assert Agent.get(ctx.adapter, & &1.snapshot.state) == "online"
    view |> element("button", "Disconnect") |> render_click()
    view |> element("button", "Disconnect Tailscale") |> render_click()
    eventually(fn -> has_element?(view, "#tailscale-save", "Connect Tailscale") end)
    refute has_element?(view, "#tailscale-login-link")
    refute has_element?(view, "button[phx-click=ask-disconnect]")
    assert Agent.get(ctx.adapter, & &1.snapshot.hostname) == "renamed-gateway"
  end

  test "draft name survives live updates and cannot overwrite another session", ctx do
    {:ok, view, _} = live(build_conn(), "/settings/tailscale")
    view |> form("#tailscale-form", remote: %{hostname: "my-draft"}) |> render_change()
    Agent.update(ctx.adapter, &put_in(&1.snapshot.hostname, "someone-else"))
    eventually(fn -> NervesGate.status().remote_access.hostname == "someone-else" end)
    assert has_element?(view, "#remote_hostname[value=my-draft]")
    assert view |> form("#tailscale-form") |> render_submit() =~ "changed in another session"
    assert Agent.get(ctx.adapter, & &1.snapshot.hostname) == "someone-else"
  end

  test "unavailable daemon is honest and cannot be configured", ctx do
    Agent.update(ctx.adapter, &put_in(&1.snapshot.available, false))
    {:ok, view, _} = live(build_conn(), "/settings/tailscale")
    assert has_element?(view, "#tailscale-save[disabled]")
    assert render(view) =~ "starting or unavailable"
  end

  test("failed input and async failures keep the entered name", ctx) do
    {:ok, view, _} = live(build_conn(), "/settings/tailscale")
    view |> form("#tailscale-form", remote: %{hostname: "invalid name"}) |> render_submit()
    assert has_element?(view, "#remote_hostname[value='invalid name']")
    assert render(view) =~ "Use 1–63"
    Agent.update(ctx.adapter, &Map.put(&1, :result, {:error, :offline}))
    view |> form("#tailscale-form", remote: %{hostname: "keep-this-name"}) |> render_submit()
    eventually(fn -> render(view) =~ "could not complete" end)
    assert has_element?(view, "#remote_hostname[value=keep-this-name]")
  end

  test(
    "login survives startup states and removes expired URLs without a public state change",
    ctx
  ) do
    Agent.update(
      ctx.adapter,
      &(&1 |> Map.put(:delay, 100) |> put_in([:snapshot, :auth_state], "unknown"))
    )

    {:ok, view, _} = live(build_conn(), "/settings/tailscale")
    view |> form("#tailscale-form", remote: %{hostname: "slow-login"}) |> render_submit()
    eventually(fn -> has_element?(view, "#tailscale-login-link") end)
    Agent.update(ctx.adapter, &%{&1 | url: nil})
    send(view.pid, :check_login)
    eventually(fn -> not has_element?(view, "#tailscale-login-link") end)
  end

  test(
    "remote access shows a simple sharing control without exposing unrelated route controls",
    ctx
  ) do
    Agent.update(ctx.adapter, fn state ->
      %{
        state
        | url: "https://login.tailscale.com/a/private-token",
          snapshot: %{
            state.snapshot
            | state: "online",
              ipv4: "100.64.1.2",
              advertised_routes: ["192.168.1.0/24"]
          }
      }
    end)

    {:ok, view, html} = live(build_conn(), "/remote")
    assert has_element?(view, "h1", "Remote access")
    assert has_element?(view, "#gateway-remote-access", "100.64.1.2")
    assert has_element?(view, "#equipment-remote-access", "Configure a dedicated equipment port")
    assert has_element?(view, "#equipment-remote-access", "Other subnet routes")
    assert has_element?(view, "a[href='/settings/tailscale']", "Manage Tailscale")
    assert has_element?(view, "#equipment-sharing-toggle[disabled]", "Turn sharing on")
    assert has_element?(view, "#equipment-sharing-state", "Off")
    refute has_element?(view, "#equipment-sharing-form")
    refute has_element?(view, "input[name='sharing[site]']")
    refute has_element?(view, "button[phx-value-route]")
    refute has_element?(view, "#calculated-via6")
    refute html =~ "private-token"
    refute html =~ "4via6"
    refute html =~ "192.168.1.0/24"
    Agent.update(ctx.adapter, &put_in(&1.snapshot.available, false))
    eventually(fn -> has_element?(view, "#equipment-sharing-state", "Unknown") end)
    assert has_element?(view, "#equipment-sharing-toggle[disabled]")
    refute has_element?(view, "#gateway-remote-access", "100.64.1.2")
  end

  test(
    "one click shares only the confirmed IPv4 subnet and turning it off preserves other routes",
    ctx
  ) do
    configure_equipment()
    Agent.update(ctx.adapter, &put_in(&1.snapshot.advertised_routes, ["fd00::/64"]))
    {:ok, view, _} = live(build_conn(), "/remote")
    assert has_element?(view, "#equipment-remote-access", "192.168.50.0/24")
    assert has_element?(view, "#equipment-sharing-toggle:not([disabled])", "Turn sharing on")
    assert Remote.status().advertised_routes == ["fd00::/64"]
    render_click(view, "enable-sharing", %{"route" => "0.0.0.0/0"})
    eventually(fn -> has_element?(view, "#equipment-sharing-state", "On") end)
    assert Remote.status().advertised_routes == ["192.168.50.0/24", "fd00::/64"]
    assert render(view) =~ "On means advertised, not verified reachable"
    assert render(view) =~ "Overlapping networks are not supported"
    refute NervesGate.status().actions["network.propose"].enabled
    view |> element("#equipment-sharing-toggle") |> render_click()
    eventually(fn -> has_element?(view, "#equipment-sharing-state", "Off") end)
    assert Remote.status().advertised_routes == ["fd00::/64"]
    assert NervesGate.status().sharing.other_routes == ["fd00::/64"]
  end

  test "remote access reports distribution without starting it on the host" do
    refute Node.alive?()
    {:ok, view, _} = live(build_conn(), "/remote")
    assert has_element?(view, "#erlang-distribution", "Erlang distribution")
    assert has_element?(view, "#distribution-disabled", "Not running")
    refute has_element?(view, "#distribution-cookie")
    refute Map.has_key?(NervesGate.status(), :distribution_cookie)
    refute Node.alive?()
  end

  test "unknown sharing is not shown as off and can be explicitly withdrawn" do
    configure_equipment()

    :sys.replace_state(Remote, fn state ->
      %{state | sharing: %{ready: true, uncertain: ["192.168.50.0/24"]}}
    end)

    {:ok, view, _} = live(build_conn(), "/remote")
    assert has_element?(view, "#equipment-sharing-state", "Unknown")
    assert has_element?(view, "#equipment-sharing-toggle:not([disabled])", "Turn sharing off")
    view |> element("#equipment-sharing-toggle") |> render_click()
    eventually(fn -> has_element?(view, "#equipment-sharing-state", "Off") end)
    assert Remote.status().sharing.uncertain == []
    assert Remote.status().advertised_routes == []
  end

  defp configure_equipment do
    settings = %{
      "mode" => "ports",
      "eth1" => nil,
      "eth0" => %{
        "role" => "equipment",
        "address" => %{
          "ip_method" => "static",
          "static_ip" => "192.168.50.2",
          "subnet_mask" => "255.255.255.0",
          "gateway" => nil
        }
      }
    }

    {:ok, id} = NervesGate.network_propose(settings)
    :ok = NervesGate.network_confirm(id)
  end

  defp eventually(fun, attempts \\ 60)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.(),
      do: :ok,
      else:
        (
          Process.sleep(10)
          eventually(fun, attempts - 1)
        )
  end
end

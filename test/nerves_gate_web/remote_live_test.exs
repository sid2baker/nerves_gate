defmodule NervesGateWeb.RemoteLiveTest do
  use ExUnit.Case, async: false
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  alias NervesGate.{Device, Remote}
  @endpoint NervesGateWeb.Endpoint

  defmodule Adapter do
    @behaviour Remote
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

    def execute(:disconnect, _, agent),
      do: Agent.update(agent, &%{&1 | url: nil, snapshot: Remote.Host.defaults()})
  end

  setup do
    Supervisor.terminate_child(NervesGate.Supervisor, Remote)
    adapter = start_supervised!({Agent, fn -> %{snapshot: Remote.Host.defaults(), url: nil} end})
    start_supervised!({Remote, adapter: {Adapter, adapter}, poll_ms: 10})
    Device.projection()
    on_exit(fn -> Supervisor.restart_child(NervesGate.Supervisor, Remote) end)
    %{adapter: adapter}
  end

  test "connect, private sign-in link, approval, live connection, rename and explicit disconnect",
       ctx do
    {:ok, view, html} = live(build_conn(), "/remote")
    assert html =~ "Tailscale"
    assert has_element?(view, "#remote_hostname[value=nerves-gate]")
    refute has_element?(view, "#tailscale-login-link")
    view |> form("#tailscale-form", remote: %{hostname: "my-gateway"}) |> render_submit()
    eventually(fn -> has_element?(view, "#tailscale-login-link") end)

    assert has_element?(
             view,
             "#tailscale-login-link[href='https://login.tailscale.com/a/private-token'][rel='noopener noreferrer'][referrerpolicy=no-referrer]"
           )

    refute Jason.encode!(Device.projection()) =~ "private-token"
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
    view |> element("button", "Cancel") |> render_click()
    assert Agent.get(ctx.adapter, & &1.snapshot.state) == "online"
    view |> element("button", "Disconnect") |> render_click()
    view |> element("button", "Disconnect Tailscale") |> render_click()
    eventually(fn -> has_element?(view, "#tailscale-save", "Connect Tailscale") end)
    refute has_element?(view, "#tailscale-login-link")
  end

  test "draft name survives live updates and cannot overwrite another session", ctx do
    {:ok, view, _} = live(build_conn(), "/remote")
    view |> form("#tailscale-form", remote: %{hostname: "my-draft"}) |> render_change()
    Agent.update(ctx.adapter, &put_in(&1.snapshot.hostname, "someone-else"))
    eventually(fn -> Device.projection().remote_access.hostname == "someone-else" end)
    assert has_element?(view, "#remote_hostname[value=my-draft]")
    assert view |> form("#tailscale-form") |> render_submit() =~ "changed in another session"
    assert Agent.get(ctx.adapter, & &1.snapshot.hostname) == "someone-else"
  end

  test "unavailable daemon is honest and cannot be configured", ctx do
    Agent.update(ctx.adapter, &put_in(&1.snapshot.available, false))
    {:ok, view, _} = live(build_conn(), "/remote")
    assert has_element?(view, "#tailscale-save[disabled]")
    assert render(view) =~ "starting or unavailable"
  end

  test("failed input and async failures keep the entered name", ctx) do
    {:ok, view, _} = live(build_conn(), "/remote")
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

    {:ok, view, _} = live(build_conn(), "/remote")
    view |> form("#tailscale-form", remote: %{hostname: "slow-login"}) |> render_submit()
    eventually(fn -> has_element?(view, "#tailscale-login-link") end)
    Agent.update(ctx.adapter, &%{&1 | url: nil})
    send(view.pid, :check_login)
    eventually(fn -> not has_element?(view, "#tailscale-login-link") end)
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

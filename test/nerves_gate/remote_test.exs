defmodule NervesGate.RemoteTest do
  use ExUnit.Case, async: true
  alias NervesGate.Remote

  defmodule Adapter do
    @behaviour NervesGate.Remote.Adapter
    def snapshot(agent), do: Agent.get(agent, & &1.snapshot)
    def login_url(agent), do: Agent.get(agent, & &1.url)

    def execute(action, params, agent) do
      data = Agent.get(agent, & &1)
      send(data.owner, {:remote_command, self(), action, params})

      receive do
        {:finish, result} -> result
      end
    end
  end

  setup do
    snapshot =
      Map.merge(Remote.unavailable(), %{
        available: true,
        state: "offline",
        auth_state: "needs_login",
        hostname: "gateway"
      })

    owner = self()
    adapter = start_supervised!({Agent, fn -> %{snapshot: snapshot, url: nil, owner: owner} end})

    remote =
      start_supervised!(
        {Remote, name: nil, adapter: {Adapter, adapter}, poll_ms: 10, timeout: 150}
      )

    %{adapter: adapter, remote: remote, api: [network: nil, remote: remote]}
  end

  test "domain queries and subscriptions do not start daemon operations", ctx do
    assert :ok = Remote.observe(ctx.remote)
    assert %{operation: nil, state: "offline"} = Remote.status(ctx.remote)
    assert Remote.login_url(ctx.remote) == nil
    assert {:error, %{code: "invalid_parameters"}} = Remote.connect("invalid name", ctx.remote)
    refute function_exported?(Remote, :command, 3)
    refute_receive {:remote_command, _, _, _}
  end

  test "named commands validate arguments and stay responsive while login runs", ctx do
    for invalid <- [
          "invalid name",
          nil,
          <<255>>,
          %{"hostname" => "gateway", "auth_key" => "secret"}
        ] do
      assert {:error, %{code: "invalid_parameters"}} = NervesGate.remote_connect(invalid, ctx.api)

      assert {:error, %{code: "invalid_parameters"}} =
               NervesGate.remote_configure(invalid, ctx.api)
    end

    refute_receive {:remote_command, _, _, _}
    assert :ok = NervesGate.remote_connect("Gateway", ctx.api)
    assert_receive {:remote_command, worker, :connect, %{hostname: "gateway"}}
    assert NervesGate.status(ctx.api).remote_access.operation == "connect"
    assert {:error, %{code: "remote_busy"}} = NervesGate.remote_disconnect(ctx.api)
    send(worker, {:finish, :ok})
    eventually(fn -> Remote.status(ctx.remote).operation == nil end)
  end

  test "configure and disconnect invoke their explicit adapter actions", ctx do
    assert :ok = NervesGate.remote_configure("New-Name", ctx.api)
    assert_receive {:remote_command, worker, :configure, %{hostname: "new-name"}}
    send(worker, {:finish, :ok})
    eventually(fn -> Remote.status(ctx.remote).operation == nil end)

    assert :ok = NervesGate.remote_disconnect(ctx.api)
    assert_receive {:remote_command, worker, :disconnect, %{}}
    send(worker, {:finish, :ok})
    eventually(fn -> Remote.status(ctx.remote).operation == nil end)
  end

  test "login URL is explicit, HTTPS-only and absent from status and broadcasts", ctx do
    url = "https://login.tailscale.com/a/private-enrollment-token"
    Agent.update(ctx.adapter, &%{&1 | url: url})
    NervesGate.subscribe(ctx.api)
    refute Jason.encode!(NervesGate.status(ctx.api)) =~ "private-enrollment-token"
    assert {:ok, ^url} = NervesGate.remote_login_url(ctx.api)

    for bad <- [
          "javascript:alert(1)",
          "http://login.tailscale.com/a/secret",
          "https://login.tailscale.com.evil.test/a/secret",
          "https://user@login.tailscale.com/a/secret"
        ] do
      Agent.update(ctx.adapter, &%{&1 | url: bad})
      assert {:ok, nil} = NervesGate.remote_login_url(ctx.api)
    end

    Agent.update(ctx.adapter, &put_in(&1.snapshot.state, "online"))
    eventually(fn -> NervesGate.status(ctx.api).remote_access.state == "online" end)
    assert_receive %PropertyTable.Event{}
    changed = NervesGate.status(ctx.api)
    assert changed.remote_access.state == "online"
    refute changed.remote_access.verified
    assert changed.remote_access.permitted_routes == nil
    refute Jason.encode!(changed) =~ "secret"
  end

  test "timeouts and failures are sanitized without blocking status or future commands", ctx do
    :ok = NervesGate.remote_connect("gateway", ctx.api)
    assert_receive {:remote_command, worker, _, _}
    send(worker, {:finish, {:error, "secret-auth-key"}})
    eventually(fn -> Remote.status(ctx.remote).error != nil end)
    assert Remote.status(ctx.remote).error.code == "remote_failed"
    refute Jason.encode!(NervesGate.status(ctx.api)) =~ "secret-auth-key"
    :ok = NervesGate.remote_configure("new-name", ctx.api)
    assert_receive {:remote_command, timed, _, _}
    eventually(fn -> Remote.status(ctx.remote).error != nil end)
    assert Remote.status(ctx.remote).error.code == "remote_timeout"
    refute Process.alive?(timed)
    assert NervesGate.status(ctx.api).actions["remote.connect"].enabled
  end

  test "unavailable daemon disables actions but not unrelated network validation", ctx do
    Agent.update(ctx.adapter, &put_in(&1.snapshot.available, false))
    refute NervesGate.status(ctx.api).capabilities.remote_enrollment
    assert {:error, %{code: "remote_unavailable"}} = NervesGate.remote_connect("gateway", ctx.api)
    assert {:ok, _} = NervesGate.network_validate(%{"mode" => "unconfigured"})

    stop_supervised!(Remote)
    assert NervesGate.status(ctx.api).remote_access.state == "unavailable"
    assert {:error, %{code: "remote_unavailable"}} = NervesGate.remote_login_url(ctx.api)
    assert {:error, %{code: "unavailable"}} = NervesGate.remote_configure("new-name", ctx.api)
  end

  test "daemon health URLs are redacted before status and broadcasts", ctx do
    NervesGate.subscribe(ctx.api)

    Agent.update(
      ctx.adapter,
      &put_in(&1.snapshot.health, [
        "Sign in at https://login.tailscale.com/a/private-token",
        "DNS warning"
      ])
    )

    status = NervesGate.status(ctx.api)
    assert status.remote_access.health == ["Sign in at [private URL]", "DNS warning"]
    refute Jason.encode!(status) =~ "private-token"
    assert_receive %PropertyTable.Event{value: changed}
    refute Jason.encode!(changed) =~ "private-token"
  end

  test "host disconnect and reconnect preserve identity, routes and unrelated settings" do
    host = start_supervised!({Remote.Host, name: nil})
    :ok = Remote.Host.execute(:connect, %{hostname: "retained-gateway"}, host)
    before = Remote.Host.snapshot(host)

    :ok =
      Remote.Host.simulate(
        Map.merge(before, %{advertised_routes: ["fd00::/64"], serve: [:kept]}),
        host
      )

    before = Remote.Host.snapshot(host)

    assert :ok = Remote.Host.execute(:disconnect, %{}, host)
    assert Remote.Host.snapshot(host) == %{before | state: "offline", auth_state: "stopped"}
    assert :ok = Remote.Host.execute(:connect, %{hostname: "retained-gateway"}, host)
    assert Remote.Host.snapshot(host) == before
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

defmodule NervesGate.RemoteTest do
  use ExUnit.Case, async: true
  alias NervesGate.{Device, Remote}

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

    device = Device.new(network: nil, remote: remote)

    %{adapter: adapter, remote: remote, device: device}
  end

  test "shared commands validate input and stay responsive while login runs", ctx do
    assert {:error, %{error: %{code: "invalid_parameters"}}} =
             dispatch(ctx, "remote.connect", %{"hostname" => "invalid name"})

    assert {:error, %{error: %{code: "invalid_parameters"}}} =
             dispatch(ctx, "remote.connect", %{"hostname" => "gateway", "auth_key" => "secret"})

    refute_receive {:remote_command, _, _, _}

    assert {:ok, %{result: %{accepted: true}}} =
             dispatch(ctx, "remote.connect", %{"hostname" => "Gateway"})

    assert_receive {:remote_command, worker, :connect, %{hostname: "gateway"}}
    assert Device.projection(ctx.device).remote_access.operation == "connect"
    assert {:error, %{error: %{code: "remote_busy"}}} = dispatch(ctx, "remote.disconnect")
    assert {:error, %{code: "remote_busy"}} = Remote.command(:disconnect, %{}, ctx.remote)
    send(worker, {:finish, :ok})
    eventually(fn -> Remote.status(ctx.remote).operation == nil end)
  end

  test "configure and disconnect route to their explicit adapter actions", ctx do
    for {id, input, action, expected} <- [
          {"remote.configure", %{"hostname" => "New-Name"}, :configure, %{hostname: "new-name"}},
          {"remote.disconnect", %{}, :disconnect, %{}}
        ] do
      assert {:ok, %{result: %{accepted: true}}} = dispatch(ctx, id, input)
      assert_receive {:remote_command, worker, ^action, ^expected}
      send(worker, {:finish, :ok})
      eventually(fn -> Remote.status(ctx.remote).operation == nil end)
    end
  end

  test "login URL is explicit, HTTPS-only and absent from projections and broadcasts", ctx do
    url = "https://login.tailscale.com/a/private-enrollment-token"
    Agent.update(ctx.adapter, &%{&1 | url: url})
    Device.subscribe(ctx.device)
    projection = Device.projection(ctx.device)
    refute Jason.encode!(projection) =~ "private-enrollment-token"
    assert {:ok, %{result: %{url: ^url}}} = dispatch(ctx, "remote.login_url")

    for bad <- [
          "javascript:alert(1)",
          "http://login.tailscale.com/a/secret",
          "https://login.tailscale.com.evil.test/a/secret",
          "https://user@login.tailscale.com/a/secret"
        ] do
      Agent.update(ctx.adapter, &%{&1 | url: bad})
      assert {:ok, %{result: %{url: nil}}} = dispatch(ctx, "remote.login_url")
    end

    Agent.update(ctx.adapter, &put_in(&1.snapshot.state, "online"))
    eventually(fn -> Device.projection(ctx.device).remote_access.state == "online" end)
    assert_receive %PropertyTable.Event{}
    changed = Device.projection(ctx.device)
    assert changed.remote_access.state == "online"
    refute changed.remote_access.verified
    assert changed.remote_access.permitted_routes == nil
    refute Jason.encode!(changed) =~ "secret"
  end

  test "timeouts and failures are sanitized without blocking status or future commands", ctx do
    {:ok, _} = dispatch(ctx, "remote.connect", %{"hostname" => "gateway"})
    assert_receive {:remote_command, worker, _, _}
    send(worker, {:finish, {:error, "secret-auth-key"}})
    eventually(fn -> Remote.status(ctx.remote).error != nil end)
    assert Remote.status(ctx.remote).error.code == "remote_failed"
    refute Jason.encode!(Device.projection(ctx.device)) =~ "secret-auth-key"
    {:ok, _} = dispatch(ctx, "remote.configure", %{"hostname" => "new-name"})
    assert_receive {:remote_command, timed, _, _}
    eventually(fn -> Remote.status(ctx.remote).error != nil end)
    assert Remote.status(ctx.remote).error.code == "remote_timeout"
    refute Process.alive?(timed)
    assert Device.projection(ctx.device).actions["remote.connect"].enabled
  end

  test "unavailable daemon disables actions but not unrelated network validation", ctx do
    Agent.update(ctx.adapter, &put_in(&1.snapshot.available, false))
    refute Device.projection(ctx.device).capabilities.remote_enrollment

    assert {:error, %{error: %{code: "remote_unavailable"}}} =
             dispatch(ctx, "remote.connect", %{"hostname" => "gateway"})

    assert {:ok, _} =
             dispatch(ctx, "network.validate", %{"network" => %{"mode" => "unconfigured"}})

    stop_supervised!(Remote)
    assert Device.projection(ctx.device).remote_access.state == "unavailable"
  end

  test("daemon health URLs are redacted before projections and broadcasts", ctx) do
    Device.subscribe(ctx.device)

    Agent.update(
      ctx.adapter,
      &put_in(&1.snapshot.health, [
        "Sign in at https://login.tailscale.com/a/private-token",
        "DNS warning"
      ])
    )

    projection = Device.projection(ctx.device)
    assert projection.remote_access.health == ["Sign in at [private URL]", "DNS warning"]
    refute Jason.encode!(projection) =~ "private-token"
    assert_receive %PropertyTable.Event{value: changed}
    refute Jason.encode!(changed) =~ "private-token"
  end

  defp dispatch(ctx, action, params \\ %{}) do
    Device.dispatch(action, params, server: ctx.device)
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

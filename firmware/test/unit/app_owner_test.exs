defmodule NervesGate.AppOwnerTest do
  use ExUnit.Case, async: false
  alias NervesGate.Apps.Owner

  defmodule Child do
    use GenServer
    def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
    def init(_), do: {:ok, Owner.resolve(self())}
    def handle_call(:startup_owner, _, state), do: {:reply, state, state}
    def handle_call({:owner, mode}, _, state), do: {:reply, Owner.resolve(self(), mode), state}
  end

  defmodule Callback do
    use Application
    def start(_, _), do: Supervisor.start_link([Child], strategy: :one_for_one)
  end

  setup do
    Owner.init()

    :ok =
      :application.load(
        {:application, :generation_fixture,
         [
           vsn: ~c"1.0.0",
           modules: [Callback, Child],
           applications: [:kernel, :stdlib, :elixir],
           mod: {Callback, []}
         ]}
      )

    on_exit(fn ->
      Application.stop(:generation_fixture)
      Application.unload(:generation_fixture)
    end)

    %{artifact: %{app: :generation_fixture, apps: [%{app: :generation_fixture}]}}
  end

  test "startup membership resolves to the managed epoch and preserves calling PID", %{
    artifact: artifact
  } do
    owner = Owner.bind(artifact, {make_ref(), 1})
    assert :ok = Application.start(:generation_fixture)
    assert {:ok, ^owner} = GenServer.call(Child, :startup_owner)
    assert {:ok, ^owner} = GenServer.call(Child, {:owner, :active})
    assert {:error, :application_not_running} = Owner.resolve(self())
    assert Owner.matches?(Process.whereis(Child), owner)
    refute Owner.matches?(self(), owner)
  end

  test "quiescing allows release but not new authority and revoked epochs stay invalid", %{
    artifact: artifact
  } do
    epoch = make_ref()
    old = Owner.bind(artifact, {epoch, 1})
    assert :ok = Application.start(:generation_fixture)
    Owner.quiesce(old)
    assert {:error, :application_not_running} = GenServer.call(Child, {:owner, :active})
    assert {:ok, ^old} = GenServer.call(Child, {:owner, :release})
    previous_pid = Process.whereis(Child)
    Owner.revoke(old)
    assert {:error, :application_not_running} = GenServer.call(Child, {:owner, :active})
    assert :ok = Application.stop(:generation_fixture)
    refute Process.alive?(previous_pid)
    current = Owner.bind(artifact, {epoch, 2})
    assert :ok = Application.start(:generation_fixture)
    assert {:ok, ^current} = GenServer.call(Child, {:owner, :active})
    refute Owner.valid?(old, :release)
    refute Owner.matches?(Process.whereis(Child), old)
  end
end

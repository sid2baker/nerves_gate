defmodule NervesGate.Tailnet.ConfigurationTest do
  use ExUnit.Case

  alias NervesGate.Settings.ChangeControl
  alias NervesGate.Tailnet.Configuration

  setup do
    owner = self()

    ops = %{
      current_profile: fn -> {:ok, "old-profile"} end,
      stage: fn token, id, previous ->
        send(owner, {:stage_profile, token, id, previous})

        {:ok,
         %{
           "previous_profile_id" => previous,
           "candidate_profile_id" => "candidate-profile"
         }}
      end,
      commit: fn rollback ->
        send(owner, {:commit_profile, rollback})
        :ok
      end,
      rollback: fn rollback ->
        send(owner, {:rollback_profile, rollback})
        :ok
      end
    }

    on_exit(fn ->
      case ChangeControl.active() do
        %{id: id} -> ChangeControl.finish(id, :test_cleanup)
        nil -> :ok
      end
    end)

    %{ops: ops}
  end

  test "the Tailnet subsystem owns temporary profiles, confirmation, and rollback", %{ops: ops} do
    configuration = start_configuration(ops, confirmation_timeout: 1_000)
    token = "tskey-auth-candidate"

    assert {:ok, pending} = Configuration.stage(token, "connection-a", configuration)
    assert_receive {:stage_profile, ^token, _id, "old-profile"}
    assert ChangeControl.active().kind == :tailnet

    assert {:error, :fresh_connection_required} =
             Configuration.confirm(pending.id, "connection-a", configuration)

    assert :ok = Configuration.confirm(pending.id, "connection-b", configuration)
    assert_receive {:commit_profile, rollback}
    assert rollback["candidate_profile_id"] == "candidate-profile"
    assert ChangeControl.active() == nil
  end

  test "the Tailnet subsystem rolls back its own profile at the deadline", %{ops: ops} do
    configuration = start_configuration(ops, confirmation_timeout: 30)

    assert {:ok, _pending} =
             Configuration.stage("tskey-auth-candidate", "connection-a", configuration)

    assert_receive {:rollback_profile, rollback}, 500
    assert rollback["previous_profile_id"] == "old-profile"
    assert Configuration.status(configuration).pending == nil
    assert ChangeControl.active() == nil
  end

  test "a subsystem restart recovers the profile from the persisted change journal", %{ops: ops} do
    name = String.to_atom("tailnet_configuration_#{System.unique_integer([:positive])}")

    {:ok, configuration} =
      Configuration.start_link(name: name, ops: ops, confirmation_timeout: 1_000)

    assert {:ok, _pending} =
             Configuration.stage("tskey-auth-candidate", "connection-a", configuration)

    GenServer.stop(configuration)
    assert_eventually(fn -> ChangeControl.active().phase == :rolling_back end)

    {:ok, restarted} =
      Configuration.start_link(name: name, ops: ops, confirmation_timeout: 1_000)

    on_exit(fn -> if Process.alive?(restarted), do: GenServer.stop(restarted) end)

    assert_receive {:rollback_profile, rollback}
    assert rollback["previous_profile_id"] == "old-profile"
    assert_eventually(fn -> ChangeControl.active() == nil end)
  end

  defp start_configuration(ops, options) do
    name = String.to_atom("tailnet_configuration_#{System.unique_integer([:positive])}")
    {:ok, configuration} = Configuration.start_link([name: name, ops: ops] ++ options)
    on_exit(fn -> if Process.alive?(configuration), do: GenServer.stop(configuration) end)
    configuration
  end

  defp assert_eventually(predicate, attempts \\ 100) do
    cond do
      predicate.() ->
        :ok

      attempts == 0 ->
        flunk("condition did not converge")

      true ->
        Process.sleep(10)
        assert_eventually(predicate, attempts - 1)
    end
  end
end

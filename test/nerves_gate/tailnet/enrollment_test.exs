defmodule NervesGate.Tailnet.EnrollmentTest do
  use ExUnit.Case

  alias NervesGate.Tailnet.Enrollment
  alias NervesGate.TestTailscaleClient
  alias Tailscale.Profile

  setup do
    {:ok, _pid} = TestTailscaleClient.reset()
    previous_client = Application.get_env(:nerves_gate, :tailscale_client)
    Application.put_env(:nerves_gate, :tailscale_client, TestTailscaleClient)

    on_exit(fn ->
      restore_env(:tailscale_client, previous_client)
      stop_if_running(TestTailscaleClient)
    end)

    :ok
  end

  test "invalid auth keys are rejected before enrollment" do
    assert {:error, :authentication_failed} = Enrollment.stage("short", "change-123", nil)
  end

  test "initial enrollment can be reverted without a previous profile" do
    assert {:ok, nil} = Enrollment.current_profile_id()

    assert {:ok, metadata} =
             Enrollment.stage("tskey-auth-candidate", "change-123", nil)

    assert metadata == %{
             "previous_profile_id" => nil,
             "candidate_profile_id" => "candidate-profile"
           }

    assert {:ok, "candidate-profile"} = Enrollment.current_profile_id()
    refute TestTailscaleClient.state().preferences.ssh
    assert :ok = Enrollment.rollback(metadata)
    assert {:ok, nil} = Enrollment.current_profile_id()
  end

  test "initial enrollment removes an untracked local profile" do
    TestTailscaleClient.put(:profiles, [
      %Profile{id: "orphan-profile", selected?: true}
    ])

    assert {:ok, _metadata} =
             Enrollment.stage("tskey-auth-candidate", "change-123", nil)

    refute Enum.any?(TestTailscaleClient.state().profiles, &(&1.id == "orphan-profile"))
  end

  test "initial rollback removes all profiles when no accepted profile exists" do
    TestTailscaleClient.put(:profiles, [
      %Profile{id: "candidate-profile", selected?: true},
      %Profile{id: "stale-profile", selected?: false}
    ])

    assert :ok =
             Enrollment.rollback(%{
               "previous_profile_id" => nil,
               "candidate_profile_id" => "candidate-profile"
             })

    assert {:ok, nil} = Enrollment.current_profile_id()
    assert TestTailscaleClient.state().profiles == []
  end

  test "staged enrollment switches back to the previous profile" do
    TestTailscaleClient.put(:profiles, [
      %Profile{id: "old-profile", nickname: "known-good", selected?: true}
    ])

    assert {:ok, metadata} =
             Enrollment.stage("tskey-auth-candidate", "change-123", "old-profile")

    assert {:ok, "candidate-profile"} = Enrollment.current_profile_id()
    assert :ok = Enrollment.rollback(metadata)
    assert {:ok, "old-profile"} = Enrollment.current_profile_id()
    refute Enum.any?(TestTailscaleClient.state().profiles, &(&1.id == "candidate-profile"))
  end

  test "unconfigured accepted settings remove every untracked profile" do
    TestTailscaleClient.put(:profiles, [
      %Profile{id: "orphan-profile", selected?: true},
      %Profile{id: "stale-profile", selected?: false}
    ])

    assert :ok = Enrollment.select(nil)
    assert {:ok, nil} = Enrollment.current_profile_id()
    assert TestTailscaleClient.state().profiles == []
  end

  test "accepted settings can restore and commit their selected profile" do
    TestTailscaleClient.put(:profiles, [
      %Profile{id: "slot-a", selected?: false},
      %Profile{id: "slot-b", selected?: true}
    ])

    assert :ok = Enrollment.select("slot-a")
    assert {:ok, "slot-a"} = Enrollment.current_profile_id()

    assert :ok =
             Enrollment.commit(%{
               "previous_profile_id" => "slot-b",
               "candidate_profile_id" => "slot-a"
             })

    refute Enum.any?(TestTailscaleClient.state().profiles, &(&1.id == "slot-b"))
  end

  test "failed online readiness returns rollback metadata" do
    TestTailscaleClient.put(:await_online, {:error, :online_timeout})

    assert {:error, :tailnet_online_timeout, metadata} =
             Enrollment.stage("tskey-auth-candidate", "change-123", nil)

    assert metadata["candidate_profile_id"] == "candidate-profile"
    assert :ok = Enrollment.rollback(metadata)
  end

  defp stop_if_running(name) do
    if pid = Process.whereis(name), do: GenServer.stop(pid)
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(key, nil), do: Application.delete_env(:nerves_gate, key)
  defp restore_env(key, value), do: Application.put_env(:nerves_gate, key, value)
end

defmodule NervesGateQEMU.EnvironmentTest do
  use ExUnit.Case, async: false

  alias NervesGateQEMU.Environment

  @auth_key "NERVES_GATE_TAILSCALE_AUTH_KEY"
  @cluster_group "NERVES_GATE_QEMU_CLUSTER_GROUP"

  setup do
    previous_auth_key = System.get_env(@auth_key)
    previous_cluster_group = System.get_env(@cluster_group)

    on_exit(fn ->
      restore(@auth_key, previous_auth_key)
      restore(@cluster_group, previous_cluster_group)
    end)

    :ok
  end

  test "process environment supplies commissioning inputs" do
    System.put_env(@auth_key, "tskey-auth-test-only")
    System.put_env(@cluster_group, "test-fleet")

    assert {:ok, "tskey-auth-test-only"} = Environment.auth_key()
    assert "test-fleet" = Environment.cluster_group()
  end

  test "cluster group has a deterministic default" do
    System.delete_env(@cluster_group)
    assert "nerves-gate-integration" = Environment.cluster_group()
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, value), do: System.put_env(key, value)
end

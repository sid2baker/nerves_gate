defmodule Workbench.TailnetAuthTest do
  use ExUnit.Case, async: false

  test "a lost enrollment reply preserves the unknown-control block" do
    previous = System.get_env("TAILSCALED_TEST_AUTH_KEY")
    System.put_env("TAILSCALED_TEST_AUTH_KEY", "private-test-key")

    on_exit(fn ->
      if previous,
        do: System.put_env("TAILSCALED_TEST_AUTH_KEY", previous),
        else: System.delete_env("TAILSCALED_TEST_AUTH_KEY")
    end)

    assert catch_exit(
             Workbench.TailnetAuth.enroll(%{node: :unreachable_tailnet_test@localhost}, "test")
           ) == :simulator_control_failed

    assert Process.get(:simulator_control_failed)

    assert catch_exit(Scenarios.Device.rpc(%{node: node()}, Kernel, :node, [])) ==
             :simulator_control_failed
  end
end

defmodule NervesGate.StatusTest do
  use ExUnit.Case, async: true

  alias NervesGate.Status

  test "only the first broken connectivity layer is failed" do
    enabled = %{enabled: true, online: false}

    assert Status.layer_states(%{online: false}, %{online: false}, enabled) == %{
             internet: :failed,
             tailnet: :blocked,
             cluster: :blocked
           }

    assert Status.layer_states(%{online: true}, %{online: false}, enabled) == %{
             internet: :ok,
             tailnet: :failed,
             cluster: :blocked
           }

    assert Status.layer_states(%{online: true}, %{online: true}, enabled) == %{
             internet: :ok,
             tailnet: :ok,
             cluster: :failed
           }
  end

  test "singular cluster mode is disabled rather than unhealthy" do
    assert Status.layer_states(
             %{online: true},
             %{online: true},
             %{enabled: false, online: false}
           ).cluster == :disabled
  end
end

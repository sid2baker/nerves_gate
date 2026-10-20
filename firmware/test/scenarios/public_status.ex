defmodule NervesGate.Scenarios.PublicStatus do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGate.TestQemu, as: Qemu

  def spec, do: %{:name => "Public status describes the QEMU device and is JSON encodable"}

  def run(%{device: vm}) do
    status = Qemu.status(vm)
    assert status.system.target == "x86_64"
    assert status.system.node == vm.node
    assert status.backend.available
    guest = status.system.node
    version = :erpc.call(guest, Application, :spec, [:tailscaled_ex, :vsn])
    assert Version.match?(to_string(version), "~> 0.4.0")
    assert is_pid(:erpc.call(guest, Process, :whereis, [Tailscaled.Supervisor]))

    assert :erpc.call(guest, Application, :get_env, [:tailscaled_ex, :data_dir]) ==
             "/data/tailscaled_ex"

    assert :erpc.call(guest, Application, :get_env, [:tailscaled_ex, :socket]) ==
             "/run/tailscale/tailscaled.sock"

    assert map_size(status.actions) > 0
    assert {:ok, _} = Jason.encode(status)
  end
end

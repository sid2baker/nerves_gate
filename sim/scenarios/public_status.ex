defmodule NervesGateSim.Scenarios.PublicStatus do
  @moduledoc false
  import ExUnit.Assertions
  alias NervesGateSim.TestQemu, as: Qemu

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
    assert status.cellular.supported == false

    for {function, args} <- [
          {:cellular_refresh, []},
          {:cellular_unlock, ["1234"]},
          {:cellular_save_pin, ["1234"]},
          {:cellular_forget_pin, []},
          {:cellular_change_pin, ["1234", "4321"]},
          {:cellular_set_pin_lock, [true, "1234"]}
        ] do
      assert {:error, %{code: "cellular_unsupported"}} =
               :erpc.call(guest, NervesGate, function, args)
    end

    for name <- ~w(refresh unlock save_pin forget_pin change_pin set_pin_lock) do
      assert status.actions["cellular.#{name}"].enabled == false
    end

    assert Map.keys(status.cellular) |> Enum.sort() ==
             Enum.sort([
               :supported,
               :enabled,
               :present,
               :sim,
               :pin_saved,
               :auto_unlock,
               :pin_lock,
               :pin_attempts_remaining,
               :registration,
               :operator,
               :signal_dbm,
               :refreshed_at,
               :operation,
               :error
             ])

    assert {:ok, _} = Jason.encode(status)
  end
end

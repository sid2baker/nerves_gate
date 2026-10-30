defmodule Scenarios.Cases.QemuStatus do
  @moduledoc false
  import ExUnit.Assertions

  def spec,
    do: %{
      name: "QEMU reports its platform and rejects unsupported cellular operations",
      requires: %{device: [], fixture: [:qemu]}
    }

  def run(%{device: vm}) do
    status = Scenarios.Device.status(vm)
    assert status.system.target == "x86_64"
    assert status.system.node == vm.node
    assert status.device.available
    version = Scenarios.Device.rpc(vm, Application, :spec, [:tailscaled_ex, :vsn])
    assert Version.match?(to_string(version), "~> 0.5.0")
    assert is_pid(Scenarios.Device.rpc(vm, Process, :whereis, [Tailscaled.Supervisor]))

    assert Scenarios.Device.rpc(vm, Application, :get_env, [:tailscaled_ex, :data_dir]) ==
             "/data/tailscaled_ex"

    assert Scenarios.Device.rpc(vm, Application, :get_env, [:tailscaled_ex, :socket]) ==
             "/run/tailscale/tailscaled.sock"

    assert map_size(status.actions) > 0
    assert status.cellular.supported == false

    for {function, args} <- [
          {:refresh, []},
          {:unlock, ["1234"]},
          {:save_pin, ["1234"]},
          {:forget_pin, []},
          {:change_pin, ["1234", "4321"]},
          {:set_pin_lock, [true, "1234"]}
        ] do
      assert {:error, %{code: "cellular_unsupported"}} =
               Scenarios.Device.rpc(vm, NervesGate.Cellular, function, args)
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
               :authentication,
               :authentication_apn,
               :pin_lock,
               :pin_attempts_remaining,
               :registration,
               :operator,
               :signal_dbm,
               :access_technology,
               :provider,
               :provider_options,
               :refreshed_at,
               :operation,
               :result,
               :error
             ])

    assert {:ok, _} = Jason.encode(status)
  end
end

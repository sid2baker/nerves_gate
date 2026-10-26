defmodule Scenarios.Apps do
  @moduledoc false
  alias Scenarios.Device

  # Called only by the runner while it holds this device. Registered versions
  # are immutable; changing a development package requires a version bump.
  def install(vm, path) do
    with {:ok, %{type: :regular, size: size}} when size <= 128 * 1024 * 1024 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, package} <- NervesGateSDK.Package.read_binary(bytes) do
      guest = "/tmp/nerves_gate_simulator-#{System.unique_integer([:positive])}.ez"

      try do
        with :ok <- Device.rpc(vm, File, :write, [guest, bytes], 30_000),
             :ok <- activate(vm, package.app, guest) do
          {:ok, "#{package.app} #{package.version}"}
        end
      after
        # Device.rpc refuses this cleanup if a preceding write's result was lost.
        Device.rpc(vm, File, :rm, [guest], 5_000)
      end
    else
      {:ok, _} -> {:error, :invalid_package}
      error -> error
    end
  end

  defp activate(vm, app, guest) do
    with {:ok, installed} <- Device.rpc(vm, NervesGate.Apps, :list, []) do
      if Enum.any?(installed, &(&1.app == to_string(app))),
        do: Device.rpc(vm, NervesGate.Apps, :upgrade, [guest], 200_000),
        else: install_and_start(vm, guest)
    end
  end

  defp install_and_start(vm, guest) do
    with {:ok, %{app: app}} <- Device.rpc(vm, NervesGate.Apps, :install, [guest], 200_000),
         do: Device.rpc(vm, NervesGate.Apps, :start, [app], 200_000)
  end
end

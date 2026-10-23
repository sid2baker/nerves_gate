defmodule Simulator.Apps do
  @moduledoc false

  # Called only by the runner while it holds this device. This is a development
  # reinstall: same-version copies are replaced, preserving app data. A new
  # version uses the device manager's ordinary health-checked upgrade.
  def install(vm, path) do
    with {:ok, %{type: :regular, size: size}} when size <= 128 * 1024 * 1024 <- File.stat(path),
         {:ok, bytes} <- File.read(path),
         {:ok, package} <- NervesGateSDK.Package.read_binary(bytes) do
      guest = "/tmp/nerves_gate_simulator-#{System.unique_integer([:positive])}.ez"

      try do
        with :ok <- :erpc.call(vm.node, File, :write, [guest, bytes], 30_000),
             :ok <- activate(vm.node, package.app, guest) do
          {:ok, "#{package.app} #{package.version}"}
        end
      after
        :erpc.call(vm.node, File, :rm, [guest], 5_000)
      end
    else
      {:ok, _} -> {:error, :invalid_package}
      error -> error
    end
  end

  defp activate(node, app, guest) do
    with {:ok, installed} <- call(node, :list, []) do
      if Enum.any?(installed, &(&1.app == to_string(app))),
        do: upgrade(node, app, guest),
        else: install_and_start(node, app, guest)
    end
  end

  defp upgrade(node, app, guest) do
    case call(node, :upgrade, [guest]) do
      {:error, :already_installed} ->
        # The device validates compatibility before reporting already_installed.
        # Only same-version development reinstalls discard the previous code;
        # versioned upgrades retain the device manager's health-checked rollback.
        with :ok <- call(node, :uninstall, [app]), do: install_and_start(node, app, guest)

      result ->
        result
    end
  end

  defp install_and_start(node, app, guest) do
    with {:ok, _} <- call(node, :install, [guest]), do: call(node, :start, [app])
  end

  defp call(node, function, args), do: :erpc.call(node, NervesGate.Apps, function, args, 60_000)
end
